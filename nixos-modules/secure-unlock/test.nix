{ nixpkgs, module }:
let
  inherit (nixpkgs) lib;
  pin = lib.concatStrings (builtins.genList (_: "a") 64);
  base = lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      module
      {
        networking.hostName = "other-host";
        system.stateVersion = "26.05";
        fileSystems."/" = { device = "/dev/mapper/system-root"; fsType = "ext4"; };
        boot.initrd.luks.devices.system-root.device = "/dev/disk/by-uuid/test-volume";
        boot.secureUnlock = {
          enable = true;
          mapperName = "system-root";
          stateDirectory = "/state";
          rootVolumeKeyId = pin;
          remoteUnlock = {
            enable = true;
            port = 2200;
            authorizedKeys = [ "ssh-ed25519 PUBLIC-TEST-FIXTURE" ];
            wifi = { enable = true; interface = "wlp2s0"; };
            tailscale.enable = true;
          };
          tpmUnlock.enable = true;
        };
      }
    ];
  };
  cfg = base.config;
  changed = settings: (base.extendModules { modules = [ settings ]; }).config;
  disabled = changed { boot.secureUnlock.enable = lib.mkForce false; };
  bootstrap = changed {
    boot.secureUnlock.rootVolumeKeyId = lib.mkForce null;
    boot.secureUnlock.remoteUnlock.enable = lib.mkForce false;
    boot.secureUnlock.tpmUnlock.enable = lib.mkForce false;
  };
  missingKeys = changed { boot.secureUnlock.remoteUnlock.authorizedKeys = lib.mkForce [ ]; };
  initrd = cfg.boot.initrd;
  target = [ "secure-unlock-recovery.target" ];
in
assert lib.assertMsg (lib.all (a: a.assertion) cfg.assertions)
  (lib.concatStringsSep "\n" (map (a: a.message) (builtins.filter (a: !a.assertion) cfg.assertions)));
assert lib.all (a: a.assertion) bootstrap.assertions;
assert lib.any (a: !a.assertion) missingKeys.assertions;
assert initrd.luks.devices.system-root.crypttabExtraOpts == [
  "fixate-volume-key=${pin}"
  "tpm2-device=auto"
  "token-timeout=10s"
];
assert !(initrd.luks.devices ? cryptroot);
assert initrd.network.ssh.port == 2200;
assert initrd.network.ssh.authorizedKeys == [ "ssh-ed25519 PUBLIC-TEST-FIXTURE" ];
assert initrd.secrets."/etc/credstore.encrypted/ssh-host-key" == "/state/credstore.encrypted/ssh-host-key";
assert lib.hasInfix "/dev/mapper/system-root" initrd.systemd.services.secure-unlock-recovery.script;
assert initrd.systemd.services.sshd.wantedBy == target;
assert initrd.systemd.services.systemd-networkd.wantedBy == target;
assert initrd.systemd.services.systemd-network-generator.wantedBy == target;
assert initrd.systemd.sockets.systemd-networkd.wantedBy == [ ];
assert initrd.systemd.services.secure-unlock-wifi.wantedBy == target;
assert initrd.systemd.services.secure-unlock-tailscale.wantedBy == target;
assert initrd.systemd.services.systemd-resolved.wantedBy == target;
assert initrd.systemd.services.secure-unlock-tailscale.conflicts == [ "initrd-switch-root.target" ];
assert initrd.systemd.services.secure-unlock-tailscale.serviceConfig.LoadCredentialEncrypted == [
  "tailscale-state:/etc/credstore.encrypted/tailscale-state"
];
assert lib.hasInfix "--state=/run/secure-unlock-tailscale/tailscaled.state" initrd.systemd.services.secure-unlock-tailscale.serviceConfig.ExecStart;
assert initrd.secrets."/etc/credstore.encrypted/tailscale-state" == "/state/credstore.encrypted/tailscale-state";
assert cfg.boot.secureUnlock.remoteUnlock.tailscale.hostName == "other-host-unlock";
assert !cfg.services.tailscale.enable;
assert !(bootstrap.boot.initrd.systemd.services ? secure-unlock-tailscale);
assert initrd.systemd.network.networks."20-wifi".matchConfig.Name == "wlp2s0";
assert cfg.systemd.services.secure-unlock-credentials.unitConfig.RequiresMountsFor == [ "/state" ];
assert cfg.boot.lanzaboote.measuredBoot.pcrlockPolicy == "/state/pcrlock.json";
assert !bootstrap.boot.initrd.network.enable;
assert !bootstrap.boot.lanzaboote.measuredBoot.enable;
assert !(disabled.systemd.services ? secure-unlock-credentials);
assert !(disabled.boot.initrd.systemd.paths ? secure-unlock-recovery);
assert !disabled.boot.lanzaboote.enable;
{
  alternateHost = true;
  recoveryOnlyNetworking = true;
  separateSealedTailscale = true;
  bootstrap = true;
  disabled = true;
  missingKeysRejected = true;
}
