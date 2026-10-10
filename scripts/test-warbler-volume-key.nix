# nix eval --impure --json --file scripts/test-warbler-volume-key.nix
let
  flake = builtins.getFlake ("path:" + toString ../.);
  base = flake.nixosConfigurations.warbler;
  lib = flake.inputs.nixpkgs.lib;
  configured = module: (base.extendModules { modules = [ module ]; }).config;
  crypttab = config: config.boot.initrd.systemd.contents."/etc/crypttab".source.text;
  failures = config: builtins.filter (a: !a.assertion) config.assertions;
  normal = configured { boot.secureUnlock.tpmUnlock.enable = lib.mkForce false; };
  tpm = configured { boot.secureUnlock.tpmUnlock.enable = lib.mkForce true; };
  missing = configured {
    boot.secureUnlock.rootVolumeKeyId = lib.mkForce null;
    boot.secureUnlock.tpmUnlock.enable = lib.mkForce false;
  };
  missingTpm = configured {
    boot.secureUnlock.rootVolumeKeyId = lib.mkForce null;
    boot.secureUnlock.remoteUnlock.enable = lib.mkForce false;
    boot.secureUnlock.tpmUnlock.enable = lib.mkForce true;
  };
  invalid = builtins.tryEval (configured { boot.secureUnlock.rootVolumeKeyId = lib.mkForce "not-a-digest"; }).boot.secureUnlock.rootVolumeKeyId;
  pin = "fixate-volume-key=${normal.boot.secureUnlock.rootVolumeKeyId}";
in
assert failures normal == [ ];
assert missing.boot.secureUnlock.rootVolumeKeyId == null;
assert base.options.boot.secureUnlock.rootVolumeKeyId.default == null;
assert failures tpm == [ ];
assert lib.hasInfix pin (crypttab normal);
assert lib.hasInfix pin (crypttab tpm);
assert !lib.hasInfix "fixate-volume-key=" (crypttab missing);
assert !lib.hasInfix "tpm2-device=" (crypttab missingTpm);
assert !missing.boot.lanzaboote.measuredBoot.enable;
assert failures missing == [ ];
assert failures missingTpm == [ ];
assert !invalid.success;
{
  manualUnlockPinned = true;
  defaultPinUnset = true;
  tpmUnlockPinned = true;
  unpinnedAttended = true;
  missingPinsDeferTpm = true;
  invalidPinRejected = true;
}
