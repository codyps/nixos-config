{ lib, rustPlatform, runtimeShell }:
rustPlatform.buildRustPackage {
  pname = "actions-vm-scaler";
  version = "0.1.0";
  src = lib.cleanSourceWith {
    src = ../scripts/actions-vm-scaler;
    filter = path: _type: baseNameOf path != "target";
  };
  cargoLock.lockFile = ../scripts/actions-vm-scaler/Cargo.lock;
  postPatch = ''
    substituteInPlace src/tests.rs --replace-fail '#!/bin/sh' '#!${runtimeShell}'
  '';
  meta = {
    description = "GitHub Actions scale sets backed by disposable QEMU VMs";
    license = lib.licenses.mit;
    mainProgram = "actions-vm-scaler";
    platforms = lib.platforms.linux;
  };
}
