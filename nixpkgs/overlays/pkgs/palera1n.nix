{
  stdenv,
  fetchFromGitHub,
  fetchurl
}:
let 
    checkra1n-kpf-pongo.src = fetchurl {
      url = "https://cdn.nickchan.lol/palera1n/artifacts/kpf/iOS15/checkra1n-kpf-pongo";
      hash = "sha256-rKWVtcb011Im2MoBhqx+0wFFTyxQsKTEEQC2xp5Z2Do=";
    };

    ramdisk.dmg.src = fetchurl {
      url = "https://cdn.nickchan.lol/palera1n/c-rewrite/deps/ramdisk.dmg";
      hash = "sha256-B/rAhsIwkkpxT+Jbm29I4oh5XhU34tlhgk918wljkVA=";
    };

    binpack.dmg.src = fetchurl {
      url = "https://cdn.nickchan.lol/palera1n/c-rewrite/deps/binpack.dmg";
      hash = "sha256-ix15wSVYRujgfib4rANQIX1POKYQM2sIVsuxvR863BM=";
    };

    pongo.bin.src = fetchurl {
      url = "https://cdn.nickchan.lol/palera1n/artifacts/kpf/iOS15/Pongo.bin";
      hash = "sha256-bwPkUeh1oSQ/P6Oc1Br4nevZT8VUepcdiHtlvFtl1RM=";
    };
in
  stdenv.mkDerivation
   rec {
    pname = "palera1n";
    version = "2.0.0-beta.8";

    src =
      fetchFromGitHub {
        owner = "palera1n";
        repo = "palera1n";
        rev = "v${version}";
        hash = "sha256-aN71y4atBdJ5J1EzSDUzTTArtAGYXs/EEFA8QhUZdXo=";
      };


    postPatch = ''
      cp -r ${checkra1n-kpf-pongo.src} checkra1n-kpf-pongo
      cp -r ${ramdisk.dmg.src} ramdisk.dmg
      cp -r ${binpack.dmg.src} binpack.dmg
      cp -r ${pongo.bin.src} pongo.bin
    '';
  }
