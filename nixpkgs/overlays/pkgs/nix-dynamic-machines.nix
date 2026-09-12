{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "nix-dynamic-machines";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ../../../scripts/nix-dynamic-machines;
    filter = path: _type: baseNameOf path != "target";
  };

  cargoLock.lockFile = ../../../scripts/nix-dynamic-machines/Cargo.lock;

  meta = {
    description = "Build a Nix remote-machines file from reachable candidates";
    license = lib.licenses.mit;
    mainProgram = "nix-dynamic-machines";
    platforms = lib.platforms.unix;
  };
}
