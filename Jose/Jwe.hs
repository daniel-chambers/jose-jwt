{-# LANGUAGE OverloadedStrings #-}

-- | JWE encrypted token support.
--
-- To create a JWE, you need to select two algorithms. One is an AES algorithm
-- used to encrypt the content of your token (for example, @A128GCM@), for which
-- a single-use key is generated internally. The second is used to encrypt
-- this content-encryption key and can be either an RSA or AES-keywrap algorithm.
-- You need to generate a suitable key to use with this, or load one from storage.
--
-- AES is much faster and creates shorter tokens, but both the encoder and decoder
-- of the token need to have a copy of the key, which they must keep secret. With
-- RSA anyone can send you a JWE if they have a copy of your public key.
--
-- In the example below, we show encoding and decoding using a 512 byte RSA key pair
-- (in practice you would use a larger key-size, for example 2048 bytes):
--
-- >>> import Jose.Jwe
-- >>> import Jose.Jwa
-- >>> import Jose.Jwk (generateRsaKeyPair, generateSymmetricKey, KeyUse(Enc), KeyId)
-- >>> (kPub, kPr) <- generateRsaKeyPair 512 (KeyId "My RSA Key") Enc Nothing
-- >>> Right (Jwt jwt) <- jwkEncode RSA_OAEP A128GCM kPub (Claims "secret claims")
-- >>> Right (Jwe (hdr, claims)) <- jwkDecode kPr jwt
-- >>> claims
-- "secret claims"
--
-- Using 128-bit AES keywrap is very similar, the main difference is that
-- we generate a 128-bit symmetric key:
--
-- >>> aesKey <- generateSymmetricKey 16 (KeyId "My Keywrap Key") Enc Nothing
-- >>> Right (Jwt jwt) <- jwkEncode A128KW A128GCM aesKey (Claims "more secret claims")
-- >>> Right (Jwe (hdr, claims)) <- jwkDecode aesKey jwt
-- >>> claims
-- "more secret claims"

module Jose.Jwe
    ( jwkEncode
    , jwkDecode
    , rsaEncode
    , rsaDecode
    )
where

import Control.Monad.Trans (lift)
import Control.Monad.Trans.Either
import Crypto.Cipher.Types (AuthTag(..))
import Crypto.PubKey.RSA (PrivateKey(..), PublicKey(..), generateBlinder, private_pub)
import Crypto.Random (MonadRandom)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Jose.Types
import qualified Jose.Internal.Base64 as B64
import Jose.Internal.Crypto
import Jose.Jwa
import Jose.Jwk
import qualified Jose.Internal.Parser as P

-- | Create a JWE using a JWK.
-- The key and algorithms must be consistent or an error
-- will be returned.
jwkEncode :: MonadRandom m
    => JweAlg                          -- ^ Algorithm to use for key encryption
    -> Enc                             -- ^ Content encryption algorithm
    -> Jwk                             -- ^ The key to use to encrypt the content key
    -> Payload                         -- ^ The token content (claims or nested JWT)
    -> m (Either JwtError Jwt)         -- ^ The encoded JWE if successful
jwkEncode a e jwk payload = runEitherT $ case jwk of
    RsaPublicJwk kPub kid _ _ -> doEncode (hdr kid) (doRsa kPub) bytes
    RsaPrivateJwk kPr kid _ _ -> doEncode (hdr kid) (doRsa (private_pub kPr)) bytes
    SymmetricJwk  kek kid _ _ -> doEncode (hdr kid) (hoistEither . keyWrap a kek) bytes
    _                         -> left $ KeyError "JWK cannot encode a JWE"
  where
    doRsa kPub = EitherT . rsaEncrypt kPub a
    hdr kid = defJweHdr {jweAlg = a, jweEnc = e, jweKid = kid, jweCty = contentType}
    (contentType, bytes) = case payload of
        Claims c       -> (Nothing, c)
        Nested (Jwt b) -> (Just "JWT", b)


-- | Try to decode a JWE using a JWK.
-- If the key type does not match the content encoding algorithm,
-- an error will be returned.
jwkDecode :: MonadRandom m
    => Jwk
    -> ByteString
    -> m (Either JwtError JwtContent)
jwkDecode jwk jwt = runEitherT $ case jwk of
    RsaPrivateJwk kPr _ _ _ -> do
        blinder <- lift $ generateBlinder (public_n $ private_pub kPr)
        e <- doDecode (rsaDecrypt (Just blinder) kPr) jwt
        return (Jwe e)
    SymmetricJwk kb   _ _ _ -> fmap Jwe (doDecode (keyUnwrap kb) jwt)
    _                       -> left $ KeyError "JWK cannot decode a JWE"


doDecode :: MonadRandom m
    => (JweAlg -> ByteString -> Either JwtError ByteString)
    -> ByteString
    -> EitherT JwtError m Jwe
doDecode decodeCek jwt = do
    encodedJwt <- hoistEither (P.parseJwt jwt)
    case encodedJwt of
        P.DecodableJwe hdr (P.EncryptedCEK ek) iv (P.Payload payload) tag (P.AAD aad) -> do
            let alg = jweAlg hdr
                enc = jweEnc hdr
            (dummyCek, _) <- lift $ generateCmkAndIV enc
            let decryptedCek = either (const dummyCek) id $ decodeCek alg ek
                cek = if B.length decryptedCek == B.length dummyCek
                        then decryptedCek
                        else dummyCek
            claims <- maybe (left BadCrypto) return $ decryptPayload enc cek iv aad tag payload
            return (hdr, claims)

        _ -> left (BadHeader "Content is not a JWE")


doEncode :: MonadRandom m
    => JweHeader
    -> (ByteString -> EitherT JwtError m ByteString)
    -> ByteString
    -> EitherT JwtError m Jwt
doEncode h encryptKey claims = do
    (cmk, iv) <- lift (generateCmkAndIV e)
    let Just (AuthTag sig, ct) = encryptPayload e cmk iv aad claims
    jweKey <- encryptKey cmk
    let jwe = B.intercalate "." $ map B64.encode [hdr, jweKey, iv, ct, BA.convert sig]
    return (Jwt jwe)
  where
    e   = jweEnc h
    hdr = encodeHeader h
    aad = B64.encode hdr

-- | Creates a JWE with the content key encoded using RSA.
rsaEncode :: MonadRandom m
    => JweAlg          -- ^ RSA algorithm to use (@RSA_OAEP@ or @RSA1_5@)
    -> Enc             -- ^ Content encryption algorithm
    -> PublicKey       -- ^ RSA key to encrypt with
    -> ByteString      -- ^ The JWT claims (content)
    -> m (Either JwtError Jwt) -- ^ The encoded JWE
rsaEncode a e kPub claims = runEitherT $ doEncode (defJweHdr {jweAlg = a, jweEnc = e}) (EitherT . rsaEncrypt kPub a) claims


-- | Decrypts a JWE.
rsaDecode :: MonadRandom m
    => PrivateKey               -- ^ Decryption key
    -> ByteString               -- ^ The encoded JWE
    -> m (Either JwtError Jwe)  -- ^ The decoded JWT, unless an error occurs
rsaDecode pk jwt = runEitherT $ do
    blinder <- lift $ generateBlinder (public_n $ private_pub pk)
    doDecode (rsaDecrypt (Just blinder) pk) jwt
