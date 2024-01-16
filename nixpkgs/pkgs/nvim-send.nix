{ lib
, rustPlatform
, fetchFromGitHub
}:

rustPlatform.buildRustPackage rec {
  pname = "nvim-send";
  version = "0.0.3";

  src = fetchFromGitHub {
    owner = "alopatindev";
    repo = "nvim-send";
    rev = version;
    hash = "sha256-V27iqRYY5vYJRMbuN3rSEV6IkRpYyqAdNa2mR9LOstI=";
  };

  cargoPatches = [
    ./0001-Cargo.lock.patch
  ];

  cargoHash = "sha256-J5mjwM1ail+gwoGeqerHF/ZvIsUaxS1QBBx4CaG1Gvs=";
}
