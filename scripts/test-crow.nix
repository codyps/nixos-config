# Evaluate with: nix eval --impure --json --file scripts/test-crow.nix
let
  flake = builtins.getFlake (toString ../.);
  lib = flake.inputs.nixpkgs.lib;
  crow = flake.nixosConfigurations.crow;
  c = crow.config;
  bootstrap = flake.nixosConfigurations.crow-bootstrap.config;
  recovery = (crow.extendModules {
    modules = [
      ({ lib, ... }: {
        # Public synthetic pin for evaluation only, never a provisioning value.
        boot.secureUnlock.rootVolumeKeyId = lib.mkForce (lib.concatStrings (lib.replicate 64 "0"));
        boot.secureUnlock.remoteUnlock.enable = lib.mkForce true;
        boot.secureUnlock.tpmUnlock.enable = lib.mkForce true;
      })
    ];
  }).config;
  failures = config: map (a: a.message) (builtins.filter (a: !a.assertion) config.assertions);
  guest = c.containers.ai.config;
in
assert failures c == [ ];
assert failures bootstrap == [ ];
assert failures recovery == [ ];
assert c.disko.devices.disk.system.content.partitions.crypt.content.content.type == "lvm_pv";
assert c.disko.devices.lvm_vg.crow.lvs.root.size == "1000000000000B";
assert c.fileSystems."/".device == "/dev/crow/root";
assert map (s: s.device) c.swapDevices == [ "/dev/crow/swap" ];
assert c.boot.initrd.services.lvm.enable;
assert c.boot.initrd.systemd.services.crow-reset-root.after == [ "dev-mapper-crow\\x2droot.device" ];
assert !c.users.users ? cody-ai;
assert guest.networking.hostName == "crow-ai";
assert guest.users.users.cody-ai.linger;
assert !guest.security.sudo.enable;
assert c.containers.ai.macvlans == [ ];
assert c.networking.nat.externalInterface == "wlp6s0";
assert c.networking.nat.internalInterfaces == [ "ve-ai" ];
assert c.containers.ai.localAddress == "10.80.0.2";
assert c.systemd.network.networks."10-ai".address == [ "10.80.0.1/24" ];
assert guest.systemd.network.networks."10-ai".address == [ "10.80.0.2/24" ];
assert guest.systemd.network.networks."10-ai".linkConfig.RequiredForOnline == "routable";
assert c.networking.wireless.iwd.enable && !c.networking.wireless.enable && !c.networking.networkmanager.enable;
assert c.networking.wireless.iwd.settings.General.EnableNetworkConfiguration == false;
assert c.systemd.network.links."10-crow-wifi".linkConfig.Name == "wlp6s0";
assert c.sops.secrets.wifi.restartUnits == [ "iwd.service" ];
assert c.sops.useSystemdActivation;
assert !bootstrap.boot.secureUnlock.remoteUnlock.enable;
assert !bootstrap.boot.secureUnlock.tpmUnlock.enable;
assert bootstrap.programs.adminCommands.commands ? setup-secure-boot;
assert !(bootstrap.programs.adminCommands.commands ? setup-luks-tpm-unlock);
assert bootstrap.environment.etc."sbctl/sbctl.conf".text == ''
  keydir: /persist/var/lib/sbctl/keys
  guid: /persist/var/lib/sbctl/GUID
'';
assert !(bootstrap.boot.initrd.secrets ? "/etc/credstore.encrypted/wifi");
assert recovery.boot.initrd.systemd.services.secure-unlock-wifi.serviceConfig.LoadCredentialEncrypted == [ "wifi:/etc/credstore.encrypted/wifi" ];
assert lib.hasInfix "/libexec/iwd" recovery.boot.initrd.systemd.services.secure-unlock-wifi.serviceConfig.ExecStart;
assert !(recovery.systemd.services ? secure-unlock-wifi);
assert recovery.boot.initrd.systemd.network.networks."20-wifi".networkConfig.DHCP == "ipv4";
{
  encryptedLvm = true;
  separateSwap = true;
  noHostAiAccount = true;
  routedContainer = true;
  sopsIwd = true;
  sealedIwdRecovery = true;
  bootstrapAttended = true;
}
