# Evaluate with: nix eval --impure --json --file scripts/test-ward.nix
let
  flake = builtins.getFlake (toString ../.);
  lib = flake.inputs.nixpkgs.lib;
  c = flake.nixosConfigurations.ward.config;
  failures = config: map (a: a.message) (builtins.filter (a: !a.assertion) config.assertions);
in
assert failures c == [ ];
assert c.boot.initrd.services.lvm.enable;
assert c.boot.initrd.luks.devices.luksroot.keyFile == null;
assert c.boot.secureUnlock.rootVolumeKeyId != null;
assert c.boot.secureUnlock.remoteUnlock.enable && c.boot.secureUnlock.tpmUnlock.enable;
assert c.boot.initrd.network.ssh.hostKeys == [ ];
assert c.boot.initrd.secrets == { };
assert c.boot.initrd.systemd.services.sshd.unitConfig.ConditionPathExists == "/.extra/global_credentials/ssh-host-key.cred";
assert builtins.elem "dev-mapper-ward\\x2dzroot.device" c.boot.initrd.systemd.services.zfs-import-ward.requires;
assert builtins.elem "dev-mapper-ward\\x2dzroot.device" c.boot.initrd.systemd.services.zfs-import-ward.after;
assert c.boot.initrd.systemd.network.networks."10-wired".dhcpV4Config.ClientIdentifier == c.systemd.network.networks."10-wired".dhcpV4Config.ClientIdentifier;
assert c.users.users.cody.hashedPasswordFile == "/persist/shadow.d/cody";
assert c.security.pam.services.passwd.rules.password.warbler-persist.control == "required";
assert !c.services.openssh.settings.PasswordAuthentication;
assert c.fileSystems."/home".device == "ward/keep/home";
assert c.fileSystems."/persist".neededForBoot;
assert !c.system.autoUpgrade.enable;
{
  pinnedStagedBoot = true;
  encryptedLvmZfsOrdering = true;
  noUsbKeyDependency = true;
  sharedPasswords = true;
  matchedDhcpIdentity = true;
}
