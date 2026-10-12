# Accept an explicit flake to test either input mode without printing values.
{ flake }:
let
  fixture = flake.lib.hardwareIdentities.fixture;
  lib = flake.inputs.nixpkgs.lib;
  darwin = flake.darwinConfigurations.u3.config;
  homes = builtins.attrValues flake.homeConfigurations;
  settings = flake.lib.hardwareIdentities.values;
  crow = flake.nixosConfigurations.crow.config;
  ward = flake.nixosConfigurations.ward.config;
  warbler = flake.nixosConfigurations.warbler.config;
in
assert crow.boot.secureUnlock.rootVolumeKeyId == settings.crow.storage.luks.cryptroot.volumeKeyId;
assert ward.boot.secureUnlock.rootVolumeKeyId == settings.ward.storage.luks.luksroot.volumeKeyId;
assert warbler.boot.secureUnlock.rootVolumeKeyId == settings.warbler.storage.luks.cryptroot.volumeKeyId;
assert (crow.system.preSwitchChecks ? rejectHardwareFixtures) == fixture;
assert (ward.system.preSwitchChecks ? rejectHardwareFixtures) == fixture;
assert (warbler.system.preSwitchChecks ? rejectHardwareFixtures) == fixture;
assert lib.hasInfix "reject-hardware-fixtures" darwin.system.activationScripts.preActivation.text == fixture;
assert builtins.all (home: (home.config.home.activation ? rejectHardwareFixtures) == fixture) homes;
{ volumePinsMatch = true; fixtureActivationGuard = true; }
