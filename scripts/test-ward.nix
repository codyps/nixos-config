# Evaluate with: nix eval --impure --json --file scripts/test-ward.nix
let
  flake = builtins.getFlake (toString ../.);
  lib = flake.inputs.nixpkgs.lib;
  c = flake.nixosConfigurations.ward.config;
  b = flake.nixosConfigurations.ward-bootstrap.config;
  failures = config: map (a: a.message) (builtins.filter (a: !a.assertion) config.assertions);
in
assert failures c == [ ];
assert failures b == [ ];
assert c.boot.initrd.services.lvm.enable;
assert c.boot.initrd.luks.devices.luksroot.keyFile == null;
assert c.boot.secureUnlock.rootVolumeKeyId == b.boot.secureUnlock.rootVolumeKeyId;
assert c.boot.secureUnlock.rootVolumeKeyId != null;
assert c.boot.secureUnlock.remoteUnlock.enable && c.boot.secureUnlock.tpmUnlock.enable;
assert !b.boot.secureUnlock.remoteUnlock.enable && !b.boot.secureUnlock.tpmUnlock.enable;
assert !b.boot.initrd.network.ssh.enable;
assert b.boot.initrd.network.ssh.hostKeys == [ ];
assert builtins.elem "dev-mapper-ward\\x2dzroot.device" b.boot.initrd.systemd.services.zfs-import-ward.requires;
assert builtins.elem "dev-mapper-ward\\x2dzroot.device" b.boot.initrd.systemd.services.zfs-import-ward.after;
assert c.boot.initrd.systemd.network.networks."10-wired".dhcpV4Config.ClientIdentifier == c.systemd.network.networks."10-wired".dhcpV4Config.ClientIdentifier;
assert c.users.users.cody.hashedPasswordFile == "/persist/shadow.d/cody";
assert c.security.pam.services.passwd.rules.password.warbler-persist.control == "required";
assert !c.services.openssh.settings.PasswordAuthentication;
assert c.fileSystems."/home".device == "ward/keep/home";
assert c.fileSystems."/persist".neededForBoot;
assert !c.system.autoUpgrade.enable;
{
  pinnedBootstrap = true;
  encryptedLvmZfsOrdering = true;
  noUsbKeyDependency = true;
  sharedPasswords = true;
  matchedDhcpIdentity = true;
}
