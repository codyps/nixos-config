{ config, lib, pkgs, utils, ... }:
let
  cfg = config.boot.secureUnlock;
  interface = cfg.remoteUnlock.wifi.interface;
  deviceUnit = "${utils.escapeSystemdPath "/sys/subsystem/net/devices/${interface}"}.device";
  credentials = "${cfg.stateDirectory}/credstore.encrypted/wifi";
  iwd = cfg.remoteUnlock.wifi.backend == "iwd";
  serviceConfig = {
    Type = "simple";
    ExecStart = "${pkgs.wpa_supplicant}/bin/wpa_supplicant -i ${interface} -c %d/wifi";
    Restart = "on-failure";
    RestartSec = "2s";
  };
in
lib.mkIf (cfg.enable && cfg.rootVolumeKeyId != null && config.boot.secureUnlock.remoteUnlock.enable && config.boot.secureUnlock.remoteUnlock.wifi.enable) {
  # Only TPM-encrypted companion ciphertext is loaded into the initrd. Decryption fails
  # closed: there is no plaintext credential fallback on the ESP.
  boot.initrd.availableKernelModules = lib.optionals iwd [ "af_alg" "algif_hash" "algif_skcipher" "cmac" "ecb" "hmac" "md5" ];
  boot.initrd.systemd = {
    storePaths = if iwd then [ "${pkgs.iwd}/libexec/iwd" ] else [ "${pkgs.wpa_supplicant}/bin/wpa_supplicant" ];
    dbus.enable = lib.mkIf iwd true;
    contents = lib.mkIf iwd {
      "/etc/iwd/main.conf".text = ''
        [General]
        EnableNetworkConfiguration=false
        [DriverQuirks]
        DefaultInterface=*
      '';
      "/etc/dbus-1".source = lib.mkForce (pkgs.makeDBusConf.override {
        inherit (config.services.dbus) apparmor;
        dbus = config.services.dbus.dbusPackage;
        suidHelper = "/bin/false";
        serviceDirectories = [ config.services.dbus.dbusPackage config.boot.initrd.systemd.package pkgs.iwd ];
      });
    };
    services.secure-unlock-wifi = {
      description = "Wi-Fi for remote LUKS unlocking";
      wantedBy = [ "secure-unlock-recovery.target" ];
      wants = [ "tpm2.target" ];
      after = [ deviceUnit "tpm2.target" "initrd-nixos-copy-secrets.service" ] ++ lib.optional iwd "dbus.service";
      requires = lib.optional iwd "dbus.service";
      bindsTo = [ deviceUnit ];
      unitConfig = {
        DefaultDependencies = false;
        ConditionPathExists = "/.extra/global_credentials/wifi.cred";
      };
      environment = lib.mkIf iwd {
        STATE_DIRECTORY = "/run/secure-unlock-iwd";
        CONFIGURATION_DIRECTORY = "/etc/iwd";
      };
      preStart = lib.mkIf iwd ''
        ${pkgs.coreutils}/bin/install -m 0600 "$CREDENTIALS_DIRECTORY/wifi" /run/secure-unlock-iwd/${cfg.remoteUnlock.wifi.iwdProfileName}
      '';
      serviceConfig = (if iwd then {
        Type = "simple";
        ExecStart = "${pkgs.iwd}/libexec/iwd --interfaces ${interface}";
        Restart = "on-failure";
        RestartSec = "2s";
        RuntimeDirectory = "secure-unlock-iwd";
        RuntimeDirectoryMode = "0700";
      } else serviceConfig) // {
        LoadCredentialEncrypted = [ "wifi:/.extra/global_credentials/wifi.cred" ];
      };
    };
    network.networks."20-wifi" = {
      matchConfig.Name = interface;
      networkConfig.DHCP = "ipv4";
    };
  };

  # Reuse the sealed copy after switching root. The authoritative plaintext
  # input stays in the configured credential store on encrypted root.
  systemd.services.secure-unlock-wifi = lib.mkIf (!iwd) {
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
