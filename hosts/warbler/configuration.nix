{ config, lib, pkgs, ... }:
let
  inherit (import ../../nixos/ssh-auth.nix) authorizedKeys;
in
{
  imports = [ ./hardware-configuration.nix ./disko.nix ./reset-root.nix ./wifi.nix ./tpm-setup.nix ./secrets.nix ];

  options.warbler.tpmUnlock.enable = lib.mkEnableOption "TPM measured-boot unlocking after enrollment";
  options.warbler.rootVolumeKeyId = lib.mkOption {
    type = lib.types.nullOr (lib.types.strMatching "[0-9a-f]{64}");
    # Public HMAC identity of the installed volume, not its encryption key.
    # Bound to the volume key, LUKS UUID, and mapper name "cryptroot".
    default = null;
    description = "Expected cryptroot volume identity from warbler-root-volume-key-id; required for remote or TPM unlock";
  };
  options.warbler.remoteUnlock.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "TPM-protected initrd SSH and Wi-Fi; disable for initial local-console provisioning";
  };

  config = {
    # Public identity of the current installation; replace after reformatting.
    warbler.rootVolumeKeyId = "4c40134b6c4df2cf83344d7b417e588f70449534f51fccce6fc5e405f8c3ea1c";
    assertions = [{
      assertion = config.warbler.rootVolumeKeyId != null
        || (!config.warbler.tpmUnlock.enable && !config.warbler.remoteUnlock.enable);
      message = "Warbler requires a pinned rootVolumeKeyId before remote or TPM unlock is enabled.";
    }];
    networking.hostName = "warbler";
    time.timeZone = "America/New_York";
    system.stateVersion = "26.05";

    # Enable only after Secure Boot is enrolled and pcrlock support is verified.
    warbler.tpmUnlock.enable = lib.mkDefault false;
    boot.loader = {
      systemd-boot.enable = lib.mkForce false;
      systemd-boot.editor = false;
      efi.canTouchEfiVariables = true;
    };
    boot.lanzaboote = {
      enable = true;
      pkiBundle = "/persist/var/lib/sbctl";
      configurationLimit = 8;
      measuredBoot = {
        enable = config.warbler.tpmUnlock.enable;
        pcrs = [ 0 4 7 ];
        pcrlockDirectory = "/persist/var/lib/pcrlock.d";
        pcrlockPolicy = "/persist/var/lib/systemd/pcrlock.json";
      };
    };
    # TPM credentials are required even when disk auto-unlock is disabled.
    security.tpm2.enable = true;
    boot.initrd = {
      systemd.enable = true;
      systemd.tpm2.enable = true;
      # Authenticate the volume before mounting it, including password recovery.
      luks.devices.cryptroot.crypttabExtraOpts = lib.optional (config.warbler.rootVolumeKeyId != null)
        "fixate-volume-key=${config.warbler.rootVolumeKeyId}"
      ++ lib.optionals config.warbler.tpmUnlock.enable [
        "tpm2-device=auto"
        "token-timeout=10s"
      ];
      network = {
        enable = true;
        ssh = {
          enable = config.warbler.remoteUnlock.enable;
          port = 2222;
          inherit authorizedKeys;
          # systemd decrypts the dedicated host key into service-private RAM.
          hostKeys = [ ];
          ignoreEmptyHostKeys = true;
          extraConfig = "HostKey /run/credentials/sshd.service/ssh-host-key";
        };
      };
      systemd.users.root.shell = "/bin/systemd-tty-ask-password-agent";
      secrets = lib.mkIf config.warbler.remoteUnlock.enable {
        "/etc/credstore.encrypted/ssh-host-key" = "/persist/credstore.encrypted/ssh-host-key";
      };
      systemd.services.sshd = lib.mkIf config.warbler.remoteUnlock.enable {
        wants = [ "tpm2.target" ];
        after = [ "tpm2.target" ];
        serviceConfig.LoadCredentialEncrypted = [ "ssh-host-key:/etc/credstore.encrypted/ssh-host-key" ];
      };
      systemd.network.networks."10-wired" = {
        matchConfig.Name = "eno1";
        networkConfig.DHCP = "ipv4";
      };
    };

    networking.useDHCP = false;
    systemd.network = {
      enable = true;
      networks."10-wired" = {
        matchConfig.Name = "eno1";
        networkConfig.DHCP = "yes";
      };
    };

    fileSystems."/persist".neededForBoot = true;
    environment.persistence."/persist" = {
      hideMounts = true;
      # /var/lib includes Tailscale's state in /var/lib/tailscale.
      directories = [ "/var/lib" "/var/log" "/var/db" "/root" ];
      files = [ "/etc/machine-id" ];
    };
    # /nix, /home and /persist live inside LUKS. No disk swap or hibernation.
    zramSwap.enable = true;

    users.mutableUsers = false;
    users.users.root = {
      hashedPassword = "!";
      openssh.authorizedKeys.keys = authorizedKeys;
    };
    users.users.cody = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      hashedPassword = "!";
      openssh.authorizedKeys.keys = authorizedKeys;
    };
    # Administration uses authorized SSH keys; no account password is embedded.
    security.sudo.wheelNeedsPassword = false;
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
      hostKeys = [{
        path = "/persist/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }];
    };
    networking.firewall.enable = true;
    # Keep this host's tailnet identity across ephemeral-root resets.
    services.tailscale.enable = true;
    environment.systemPackages = (with pkgs; [ sbctl cryptsetup tpm2-tools neovim htop tmux ]) ++ [
      (pkgs.callPackage ./root-volume-key-id.nix {
        device = config.boot.initrd.luks.devices.cryptroot.device;
      })
    ];

    # Explicit upgrades while Secure Boot/TPM enrollment is being established.
    system.autoUpgrade.enable = lib.mkForce false;
    p.nix.buildMachines.ward.enable = lib.mkForce false;
  };
}
