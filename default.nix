# This file was auto-generated by cabal2nix. Please do NOT edit manually!

{ cabal, aeson, base64Bytestring, byteable, cereal, cipherAes
, cprngAes, cryptoCipherTypes, cryptohash, cryptoNumbers
, cryptoPubkey, cryptoRandom, doctest, either, errors, hspec, HUnit
, mtl, QuickCheck, text, time, unorderedContainers, vector
}:

cabal.mkDerivation (self: {
  pname = "jose-jwt";
  version = "0.2";
  src = ./.;
  buildDepends = [
    aeson base64Bytestring byteable cereal cipherAes cryptoCipherTypes
    cryptohash cryptoNumbers cryptoPubkey cryptoRandom errors mtl text
    time unorderedContainers vector
  ];
  testDepends = [
    aeson base64Bytestring cipherAes cprngAes cryptoCipherTypes
    cryptohash cryptoPubkey cryptoRandom doctest either hspec HUnit mtl
    QuickCheck text
  ];
  meta = {
    homepage = "http://github.com/tekul/jose-jwt";
    description = "JSON Object Signing and Encryption Library";
    license = self.stdenv.lib.licenses.bsd3;
    platforms = self.ghc.meta.platforms;
  };
})
