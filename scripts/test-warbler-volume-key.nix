# nix eval --impure --json --file scripts/test-warbler-volume-key.nix
let
  flake = builtins.getFlake ("path:" + toString ../.);
  base = flake.nixosConfigurations.warbler;
  lib = flake.inputs.nixpkgs.lib;
  configured = module: (base.extendModules { modules = [ module ]; }).config;
  crypttab = config: config.boot.initrd.systemd.contents."/etc/crypttab".source.text;
  failures = config: builtins.filter (a: !a.assertion) config.assertions;
  normal = configured { warbler.tpmUnlock.enable = lib.mkForce false; };
  tpm = configured { warbler.tpmUnlock.enable = lib.mkForce true; };
  bootstrap = flake.nixosConfigurations.warbler-bootstrap.config;
  missing = configured {
    warbler.rootVolumeKeyId = lib.mkForce null;
    warbler.tpmUnlock.enable = lib.mkForce false;
  };
  missingTpm = configured {
    warbler.rootVolumeKeyId = lib.mkForce null;
    warbler.remoteUnlock.enable = lib.mkForce false;
    warbler.tpmUnlock.enable = lib.mkForce true;
  };
  invalid = builtins.tryEval (configured { warbler.rootVolumeKeyId = lib.mkForce "not-a-digest"; }).warbler.rootVolumeKeyId;
  pin = "fixate-volume-key=${normal.warbler.rootVolumeKeyId}";
in
assert failures normal == [ ];
assert missing.warbler.rootVolumeKeyId == null;
assert base.options.warbler.rootVolumeKeyId.default == null;
assert failures tpm == [ ];
assert failures bootstrap == [ ];
assert lib.hasInfix pin (crypttab normal);
assert lib.hasInfix pin (crypttab tpm);
assert !lib.hasInfix "fixate-volume-key=" (crypttab bootstrap);
assert !bootstrap.warbler.remoteUnlock.enable && !bootstrap.warbler.tpmUnlock.enable;
assert builtins.length (failures missing) == 1;
assert builtins.length (failures missingTpm) == 1;
assert !invalid.success;
{
  manualUnlockPinned = true;
  defaultPinUnset = true;
  tpmUnlockPinned = true;
  bootstrapAttended = true;
  missingPinsRejected = true;
  invalidPinRejected = true;
}
