{ config, lib, pkgs, ... }:
let
  cfg = config.boot.secureUnlock;
  inherit (lib) mkOption types;
in
{
  imports = [ ./remote-unlock.nix ./wifi.nix ./tpm-setup.nix ];

  options.boot.secureUnlock = {
    enable = lib.mkEnableOption "pinned LUKS root with Secure Boot, remote recovery and optional TPM unlocking";
    mapperName = mkOption {
      type = types.strMatching "[a-zA-Z0-9_-]+";
      default = "cryptroot";
      description = "Name of the existing boot.initrd.luks.devices entry for the root volume.";
    };
    stateDirectory = mkOption {
      type = types.strMatching "/[a-zA-Z0-9_./-]+";
      default = "/var/lib/secure-unlock";
      description = "Persistent directory on the encrypted root volume for plaintext and sealed credentials.";
    };
    rootVolumeKeyId = mkOption {
      type = types.nullOr (types.strMatching "[0-9a-f]{64}");
      default = null;
      description = "Public identity from root-volume-key-id; required before enabling remote or TPM unlock.";
    };
    tpmUnlock.enable = lib.mkEnableOption "TPM measured-boot unlocking after explicit enrollment";
    remoteUnlock = {
      enable = lib.mkEnableOption "TPM-sealed initrd SSH recovery when a passphrase is requested";
      authorizedKeys = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "SSH public keys allowed to answer initrd passphrase requests.";
      };
      port = mkOption {
        type = types.port;
        default = 2222;
        description = "Initrd recovery SSH port.";
      };
      wifi = {
        enable = lib.mkEnableOption "Wi-Fi for initrd recovery and the running system";
        interface = mkOption {
          type = types.strMatching "[a-zA-Z0-9_-]+";
          default = "wlan0";
          description = "Wi-Fi interface; install its wpa_supplicant input in stateDirectory/credstore/wifi.";
        };
      };
    };
    volumeIdentityPackage = mkOption {
      type = types.package;
      readOnly = true;
      description = "Volume identity helper configured for this host's LUKS device and mapper name.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.rootVolumeKeyId != null || (!cfg.tpmUnlock.enable && !cfg.remoteUnlock.enable);
        message = "secureUnlock requires a pinned rootVolumeKeyId before remote or TPM unlock is enabled.";
      }
      {
        assertion = !cfg.remoteUnlock.enable || cfg.remoteUnlock.authorizedKeys != [ ];
        message = "secureUnlock remote recovery requires at least one SSH authorized key.";
      }
    ];
    boot.secureUnlock.volumeIdentityPackage = pkgs.callPackage ./root-volume-key-id.nix {
      device = config.boot.initrd.luks.devices.${cfg.mapperName}.device;
      inherit (cfg) mapperName;
    };
    environment.systemPackages = [ cfg.volumeIdentityPackage ];
    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.loader.systemd-boot.editor = false;
    boot.lanzaboote = {
      enable = true;
      configurationLimit = lib.mkDefault 8;
      pkiBundle = lib.mkDefault "${cfg.stateDirectory}/sbctl";
      measuredBoot = {
        enable = cfg.tpmUnlock.enable;
        pcrs = [ 0 4 7 ];
        pcrlockDirectory = lib.mkDefault "${cfg.stateDirectory}/pcrlock.d";
        pcrlockPolicy = lib.mkDefault "${cfg.stateDirectory}/pcrlock.json";
      };
    };
    security.tpm2.enable = true;
    boot.initrd = {
      systemd.enable = true;
      systemd.tpm2.enable = true;
      luks.devices.${cfg.mapperName}.crypttabExtraOpts =
        lib.optional (cfg.rootVolumeKeyId != null) "fixate-volume-key=${cfg.rootVolumeKeyId}"
        ++ lib.optionals cfg.tpmUnlock.enable [ "tpm2-device=auto" "token-timeout=10s" ];
      network = {
        enable = cfg.remoteUnlock.enable;
        ssh = {
          enable = cfg.remoteUnlock.enable;
          inherit (cfg.remoteUnlock) port authorizedKeys;
          hostKeys = [ ];
          ignoreEmptyHostKeys = true;
          extraConfig = "HostKey /run/credentials/sshd.service/ssh-host-key";
        };
      };
      systemd.users.root.shell = lib.mkIf cfg.remoteUnlock.enable "/bin/systemd-tty-ask-password-agent";
      secrets = lib.mkIf cfg.remoteUnlock.enable {
        "/etc/credstore.encrypted/ssh-host-key" = "${cfg.stateDirectory}/credstore.encrypted/ssh-host-key";
      };
      systemd.services.sshd = lib.mkIf cfg.remoteUnlock.enable {
        wants = [ "tpm2.target" ];
        after = [ "tpm2.target" ];
        serviceConfig.LoadCredentialEncrypted = [ "ssh-host-key:/etc/credstore.encrypted/ssh-host-key" ];
      };
    };
  };
}
