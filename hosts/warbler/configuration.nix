{ config, lib, pkgs, ... }:
let
  inherit (import ../../nixos/ssh-auth.nix) authorizedKeys;
  # Preserve eno1's existing lease across initrd and normal boot. The initrd
  # cannot use the machine-id stored on encrypted /persist. These DHCP
  # identifiers are public; DUIDRawData excludes the two-byte DUID type.
  wiredDhcpIdentity = {
    DUIDType = "vendor";
    DUIDRawData = "00:00:ab:11:21:c2:67:af:22:79:38:e4";
    IAID = 3055685611;
  };
  wiredDhcpConfig = {
    dhcpV4Config = wiredDhcpIdentity // { ClientIdentifier = "duid"; };
    dhcpV6Config = wiredDhcpIdentity;
  };
in
{
  imports = [ ./hardware-configuration.nix ./disko.nix ./reset-root.nix ../../nixos-modules/secure-unlock ./secrets.nix ./usbguard.nix ./account-passwords.nix ];

  config = {
    boot.secureUnlock.rootVolumeKeyId = import ./volume-identity.nix;
    networking.hostName = "warbler";
    time.timeZone = "America/New_York";
    system.stateVersion = "26.05";

    boot.secureUnlock.enable = true;
    boot.secureUnlock.stateDirectory = "/persist";
    boot.secureUnlock.remoteUnlock.authorizedKeys = authorizedKeys;
    boot.secureUnlock.remoteUnlock.wifi.interface = "wlp3s0";
    boot.secureUnlock.tpmUnlock.enable = true;
    boot.secureUnlock.remoteUnlock.enable = true;

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
    services.tailscale.enable = true;
    environment.systemPackages = (with pkgs; [ sbctl cryptsetup tpm2-tools neovim htop tmux ghostty.terminfo ]) ++ [
      (pkgs.callPackage ./secure-boot-backup.nix { })
    ];

    system.autoUpgrade.enable = lib.mkForce false;
    p.nix.buildMachines.ward.enable = lib.mkForce false;
  };
}
