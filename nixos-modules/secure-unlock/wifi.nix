{ config, lib, pkgs, utils, ... }:
let
  cfg = config.boot.secureUnlock;
  interface = cfg.remoteUnlock.wifi.interface;
  deviceUnit = "${utils.escapeSystemdPath "/sys/subsystem/net/devices/${interface}"}.device";
  credentials = "${cfg.stateDirectory}/credstore.encrypted/wifi";
  serviceConfig = {
    Type = "simple";
    ExecStart = "${pkgs.wpa_supplicant}/bin/wpa_supplicant -i ${interface} -c %d/wifi";
    Restart = "on-failure";
    RestartSec = "2s";
  };
in
lib.mkIf (cfg.enable && config.boot.secureUnlock.remoteUnlock.enable && config.boot.secureUnlock.remoteUnlock.wifi.enable) {
  # Only TPM-encrypted ciphertext is appended to the initrd. Decryption fails
  # closed: there is no plaintext credential fallback on the ESP.
  boot.initrd.secrets."/etc/credstore.encrypted/wifi" = credentials;
  boot.initrd.systemd = {
    storePaths = [ "${pkgs.wpa_supplicant}/bin/wpa_supplicant" ];
    services.secure-unlock-wifi = {
      description = "Wi-Fi for remote LUKS unlocking";
      wantedBy = [ "secure-unlock-recovery.target" ];
      wants = [ "tpm2.target" ];
      after = [ deviceUnit "tpm2.target" "initrd-nixos-copy-secrets.service" ];
      bindsTo = [ deviceUnit ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = serviceConfig // {
        LoadCredentialEncrypted = [ "wifi:/etc/credstore.encrypted/wifi" ];
      };
    };
    network.networks."20-wifi" = {
      matchConfig.Name = interface;
      networkConfig.DHCP = "ipv4";
    };
  };

  # Reuse the sealed copy after switching root. The authoritative plaintext
  # input stays in the configured credential store on encrypted root.
  systemd.services.secure-unlock-wifi = {
    description = "Wi-Fi with TPM-encrypted credentials";
    wantedBy = [ "multi-user.target" ];
    wants = [ "tpm2.target" ];
    requires = [ "secure-unlock-credentials.service" ];
    after = [ deviceUnit "tpm2.target" "secure-unlock-credentials.service" ];
    bindsTo = [ deviceUnit ];
    unitConfig.RequiresMountsFor = [ cfg.stateDirectory ];
    serviceConfig = serviceConfig // {
      LoadCredentialEncrypted = [ "wifi:${credentials}" ];
    };
  };
  systemd.network.enable = true;
  systemd.network.networks."20-wifi" = {
    matchConfig.Name = interface;
    networkConfig.DHCP = "yes";
  };
}
