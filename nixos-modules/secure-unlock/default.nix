{ config, lib, pkgs, ... }:
let
  cfg = config.boot.secureUnlock;
  inherit (lib) mkOption types;
  remote = cfg.remoteUnlock.enable && cfg.rootVolumeKeyId != null;
in
{
  imports = [ ../../modules/admin-commands.nix ./remote-unlock.nix ./wifi.nix ./tailscale.nix ./tpm-setup.nix ./bootloader.nix ];

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
      description = "Public identity from root-volume-key-id; required before provisioning remote or TPM unlock. Null permits attended installation only.";
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
      tailscale = {
        enable = lib.mkEnableOption "a separate TPM-sealed Tailscale identity for initrd recovery";
        hostName = mkOption {
          type = types.strMatching "[a-zA-Z0-9][a-zA-Z0-9-]*";
          default = "${config.networking.hostName}-unlock";
          description = "Hostname of the separately registered, non-expiring initrd Tailscale node.";
        };
      };
      wifi = {
        enable = lib.mkEnableOption "Wi-Fi for initrd recovery and the running system";
        backend = mkOption {
          type = types.enum [ "wpa_supplicant" "iwd" ];
          default = "wpa_supplicant";
          description = "Wi-Fi daemon used for recovery. With iwd, configure stage-2 Wi-Fi separately.";
        };
        iwdProfileName = mkOption {
          type = types.strMatching "[a-zA-Z0-9=_-]+\\.(psk|8021x|open)";
          default = "network.psk";
          description = "iwd network profile filename, including its security extension.";
        };
        interface = mkOption {
          type = types.strMatching "[a-zA-Z0-9_-]+";
          default = "wlan0";
          description = "Wi-Fi interface; install its backend's network profile in stateDirectory/credstore/wifi.";
        };
      };
    };
    provisioningPackage = mkOption {
      type = types.package;
      readOnly = true;
      internal = true;
      description = "Staged credential provisioning helper.";
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
        assertion = !cfg.remoteUnlock.enable || cfg.remoteUnlock.authorizedKeys != [ ];
        message = "secureUnlock remote recovery requires at least one SSH authorized key.";
      }
    ];
    boot.secureUnlock.volumeIdentityPackage = pkgs.callPackage ./root-volume-key-id.nix {
      device = config.boot.initrd.luks.devices.${cfg.mapperName}.device;
      inherit (cfg) mapperName;
    };
    environment.systemPackages = [ cfg.volumeIdentityPackage ];
    programs.adminCommands.commands.root-volume-key-id = [ "${cfg.volumeIdentityPackage}/bin/root-volume-key-id" ];
    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.loader.systemd-boot.editor = false;
    boot.lanzaboote = {
      enable = true;
      configurationLimit = lib.mkDefault 4;
      pkiBundle = lib.mkDefault "${cfg.stateDirectory}/sbctl";
      measuredBoot = {
        enable = cfg.tpmUnlock.enable && cfg.rootVolumeKeyId != null;
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
        ++ lib.optionals (cfg.tpmUnlock.enable && cfg.rootVolumeKeyId != null) [ "tpm2-device=auto" "token-timeout=10s" ];
      network = {
        enable = remote;
        ssh = {
          enable = remote;
          inherit (cfg.remoteUnlock) port authorizedKeys;
          hostKeys = [ ];
          ignoreEmptyHostKeys = true;
          extraConfig = "HostKey /run/credentials/sshd.service/ssh-host-key";
        };
      };
      systemd.users.root.shell = lib.mkIf remote "/bin/systemd-tty-ask-password-agent";
      systemd.services.sshd = lib.mkIf remote {
        unitConfig.ConditionPathExists = "/.extra/global_credentials/ssh-host-key.cred";
        wants = [ "tpm2.target" ];
        after = [ "tpm2.target" ];
        serviceConfig.LoadCredentialEncrypted = [ "ssh-host-key:/.extra/global_credentials/ssh-host-key.cred" ];
      };
    };
  };
}
