{ config, lib, pkgs, ... }:
let
  interface = "wlp3s0";
  deviceUnit = "sys-subsystem-net-devices-${interface}.device";
  credentials = "/persist/credstore.encrypted/wifi";
  serviceConfig = {
    Type = "simple";
    ExecStart = "${pkgs.wpa_supplicant}/bin/wpa_supplicant -i ${interface} -c %d/wifi";
    Restart = "on-failure";
    RestartSec = "2s";
  };
in
lib.mkIf (config.warbler.remoteUnlock.enable && config.warbler.remoteUnlock.wifi.enable) {
  # Only TPM-encrypted ciphertext is appended to the initrd. Decryption fails
  # closed: there is no plaintext credential fallback on the ESP.
  boot.initrd.secrets."/etc/credstore.encrypted/wifi" = credentials;
  boot.initrd.systemd = {
    storePaths = [ "${pkgs.wpa_supplicant}/bin/wpa_supplicant" ];
    services.warbler-wifi = {
      description = "Wi-Fi for remote LUKS unlocking";
      wantedBy = [ "warbler-remote-unlock.target" ];
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
  # input stays on encrypted cryptroot under /persist/credstore.
  systemd.services.warbler-wifi = {
    description = "Wi-Fi with TPM-encrypted credentials";
    wantedBy = [ "multi-user.target" ];
    wants = [ "tpm2.target" ];
    requires = [ "warbler-initrd-credentials.service" ];
    after = [ deviceUnit "tpm2.target" "warbler-initrd-credentials.service" ];
    bindsTo = [ deviceUnit ];
    unitConfig.RequiresMountsFor = [ "/persist" ];
    serviceConfig = serviceConfig // {
      LoadCredentialEncrypted = [ "wifi:${credentials}" ];
    };
  };
  systemd.network.networks."20-wifi" = {
    matchConfig.Name = interface;
    networkConfig.DHCP = "yes";
  };
}
