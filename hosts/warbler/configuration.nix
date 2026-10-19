{ config, lib, pkgs, hardwareIdentities, ... }:
let
  inherit (import ../../nixos/ssh-auth.nix) authorizedKeys;
  # Preserve eno1's existing lease across initrd and normal boot. The initrd
  # cannot use the machine-id stored on encrypted /persist. These DHCP
  # identifiers are public; DUIDRawData excludes the two-byte DUID type.
  wiredDhcpIdentity = {
    DUIDType = "vendor";
  };
  wiredDhcpConfig = {
    dhcpV4Config = wiredDhcpIdentity // { ClientIdentifier = "duid"; };
    dhcpV6Config = wiredDhcpIdentity;
  };
in
{
  imports = [ ./hardware-configuration.nix ./disko.nix ./reset-root.nix ../../nixos-modules/secure-unlock ./secrets.nix ./usbguard.nix ./account-passwords.nix ./ai-harnesses.nix ./ai-container.nix ./garm.nix ./zpl-proxy-api.nix ./hindsight.nix ./actions-vm-scaler.nix ../../nixos-modules/actions-vm-image.nix ];

  config = {
    # warbler-ai owns the primary Codex runtime. Retain the old account/home
    # for migration and recovery, without competing daemon supervision.
    systemd.services.codex-ai.enable = false;
    programs.actions-vm-image.enable = true;
    programs.adminCommands.commands.backup-secure-boot = [ "${pkgs.callPackage ./secure-boot-backup.nix { }}/bin/warbler-secure-boot-backup" ];
    boot.secureUnlock.rootVolumeKeyId = import ./volume-identity.nix { inherit hardwareIdentities; };
    services.hardwareIdentities.templates."etc/systemd/network/10-wired.network.d/90-hardware.conf" = {
      initrd = true;
      text = ''
        [DHCPv4]
        DUIDRawData=${hardwareIdentities "warbler" [ "network" "interfaces" "eno1" "dhcp" "duid" ]}
        IAID=${toString (hardwareIdentities "warbler" [ "network" "interfaces" "eno1" "dhcp" "iaid" ])}
        [DHCPv6]
        DUIDRawData=${hardwareIdentities "warbler" [ "network" "interfaces" "eno1" "dhcp" "duid" ]}
        IAID=${toString (hardwareIdentities "warbler" [ "network" "interfaces" "eno1" "dhcp" "iaid" ])}
      '';
    };
    networking.hostName = "warbler";
    time.timeZone = "America/New_York";
    system.stateVersion = "26.05";

    boot.secureUnlock.enable = true;
    boot.secureUnlock.stateDirectory = "/persist";
    boot.secureUnlock.remoteUnlock.authorizedKeys = authorizedKeys;
    boot.secureUnlock.remoteUnlock.wifi.interface = "wlp3s0";
    boot.secureUnlock.tpmUnlock.enable = true;
    boot.secureUnlock.remoteUnlock.enable = true;
    boot.secureUnlock.remoteUnlock.tailscale.enable = true;

    boot.loader = {
      efi.canTouchEfiVariables = true;
    };
    boot.lanzaboote = {
      pkiBundle = "/persist/var/lib/sbctl";
      measuredBoot = {
        pcrlockDirectory = "/persist/var/lib/pcrlock.d";
        pcrlockPolicy = "/persist/var/lib/systemd/pcrlock.json";
      };
    };
    boot.initrd = {
      systemd.network.networks."10-wired" = wiredDhcpConfig // {
        matchConfig.Name = "eno1";
        networkConfig.DHCP = "ipv4";
      };
    };

    networking.useDHCP = false;
    systemd.network = {
      enable = true;
      networks."10-wired" = wiredDhcpConfig // {
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
    zramSwap.enable = true;

    users.users.root = {
      openssh.authorizedKeys.keys = authorizedKeys;
    };
    users.users.cody = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = authorizedKeys;
    };
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
    services.tailscale = {
      enable = true;
      useRoutingFeatures = "server";
      extraSetFlags = [ "--advertise-exit-node" ];
    };
    environment.systemPackages = (with pkgs; [ sbctl cryptsetup tpm2-tools neovim htop ncdu tmux ghostty.terminfo ]) ++ [
      (pkgs.callPackage ./secure-boot-backup.nix { })
    ];

    # Collect before a large build consumes the last working space. This can
    # reclaim unrooted store paths, but cannot evict project data or GC roots.
    nix.settings = {
      min-free = 20 * 1024 * 1024 * 1024;
      max-free = 40 * 1024 * 1024 * 1024;
    };
    nix.gc = {
      dates = lib.mkForce "daily";
      options = lib.mkForce "--delete-older-than 14d";
    };
    services.journald.settings.Journal = {
      SystemMaxUse = "1G";
      SystemKeepFree = "4G";
    };
    containers.ai.config.services.journald.settings.Journal = {
      SystemMaxUse = "512M";
      SystemKeepFree = "4G";
    };

    system.autoUpgrade.enable = lib.mkForce false;
    p.nix.buildMachines.ward.enable = lib.mkForce false;
  };
}
