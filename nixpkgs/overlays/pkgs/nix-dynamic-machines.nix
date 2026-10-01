{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "nix-dynamic-machines";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ../../../scripts/nix-dynamic-machines;
    filter = path: _type: baseNameOf path != "target";
  };

  cargoLock.lockFile = ../../../scripts/nix-dynamic-machines/Cargo.lock;

  # Tests write executable fixtures while other tests fork probes. A fork can
  # briefly inherit a writable fixture descriptor before exec closes it, causing
  # ETXTBSY on Linux. Serialize test cases; each still tests concurrent probes.
  checkFlags = [ "--test-threads=1" ];

  meta = {
    description = "Build a Nix remote-machines file from reachable candidates";
    license = lib.licenses.mit;
    mainProgram = "nix-dynamic-machines";
    platforms = lib.platforms.unix;
  };
}
