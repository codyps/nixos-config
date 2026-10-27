# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib, modulesPath, self, hardwareIdentities, ... }:

let
  ssh-auth = (import ../../nixos/ssh-auth.nix);
  authorizedKeys = ssh-auth.authorizedKeys;
in
{
  imports =
    [
      ../../nixos-modules/all-modules.nix
      ./hardware-configuration.nix
      (modulesPath + "/virtualisation/xen-domU.nix")
    ];

  services.logrotate.checkConfig = false;

  system.autoUpgrade.enable = lib.mkForce false;
  nix.optimise.automatic = lib.mkForce false;
  nix.gc.automatic = lib.mkForce false;

  boot.zfs.extraPools = [ "tank" ];

  # Without this, boot ends up in grup rescue.
  boot.loader.grub.device = lib.mkForce "/dev/xvda";
  boot.zfs.devNodes = "/dev/disk/by-partuuid";

  p.zfs.root-impermenance = {
    enable = true;
    rollback-target = "rpool/local/root@blank";
  };

  fileSystems."/persist".neededForBoot = true;

  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib"
      "/var/db"
    ];
  };

  environment.shells = with pkgs; [ zsh ];

  /*
    services.harmonia = {
    enable = false;
    signKeyPath = "/persist/var/lib/secrets/harmonia.secret";
    # let's not bind to the wildcard address.
    settings = {
      bind = "[::1]:5000";
    };
    };
  */

  /*
    services.atticd = {
    # Replace with absolute path to your credentials file
    credentialsFile = "/persist/etc/atticd.env";

    settings = {
      listen = "[::]:8080";

      # Data chunking
      #
      # Warning: If you change any of the values here, it will be
      # difficult to reuse existing chunks for newly-uploaded NARs
      # since the cutpoints will be different. As a result, the
      # deduplication ratio will suffer for a while after the change.
      chunking = {
        # The minimum NAR size to trigger chunking
        #
        # If 0, chunking is disabled entirely for newly-uploaded NARs.
        # If 1, all NARs are chunked.
        nar-size-threshold = 64 * 1024; # 64 KiB

        # The preferred minimum size of a chunk, in bytes
        min-size = 16 * 1024; # 16 KiB

        # The preferred average size of a chunk, in bytes
        avg-size = 64 * 1024; # 64 KiB

        # The preferred maximum size of a chunk, in bytes
        max-size = 256 * 1024; # 256 KiB
      };
    };
    };
  */

  /*
    services.hydra = {
    enable = false;
    hydraURL = "https://hydra.finch.einic.org/";
    notificationSender = "hydra@localhost";
    buildMachinesFiles = [];
    useSubstitutes = true;
    listenHost = "localhost";
    };
  */


  # Migrated to Robin. Keep these disabled across rebuilds and reboots:
  # both hosts must never run the copied Syncthing identity simultaneously.
  services.syncthing.enable = lib.mkForce false;
  services.audiobookshelf.enable = lib.mkForce false;
  services.caddy.enable = lib.mkForce false;
  virtualisation.oci-containers.containers = lib.mkForce { };

  # Explicit masks also cover units left behind by the old configuration.
  systemd.services = lib.genAttrs [
    "syncthing"
    "audiobookshelf"
    "caddy"
    "podman-libation"
    "podman-storyteller"
  ]
    (_: { enable = false; });
  systemd.sockets.caddy.enable = false;
  systemd.timers.podman-libation.enable = false;

  networking.hostId = "${hardwareIdentities "finch" [ "storage" "zfs" "hostId" ]}";
  networking.hostName = "finch";
  networking.useDHCP = false;

  systemd.network = {
    enable = true;
    wait-online.anyInterface = true;
    networks."10-enX0" = {
      matchConfig.Name = "enX0";
      dns = [
        "1.1.1.1"
        "1.0.0.1"
      ];
      address = [
        "207.90.192.55/24"
      ];
      gateway = [ "207.90.192.1" ];
    };

    networks."10-enX1" = {
      matchConfig.Name = "enX1";
      dns = [
        "2606:4700:4700::1111"
        "2606:4700:4700::1001"
      ];
      address = [
        "2602:ffd5:0001:1e7:0000:0000:0000:0001/36"
      ];
      gateway = [ "2602:ffd5:1:100::1" ];
    };

    networks."50-tailscale" = {
      name = "tailscale*";
      linkConfig = {
        Unmanaged = true;
        ActivationPolicy = "manual";
      };
    };
  };

  time.timeZone = "America/New_York";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  #   useXkbConfig = true; # use xkbOptions in tty.
  # };

  users.mutableUsers = false;
  users.defaultUserShell = pkgs.zsh;
  users.users.root = {
    openssh.authorizedKeys.keys = authorizedKeys;
    hashedPasswordFile = "/persist/etc/passwd.d/root";
  };
  users.users.cody = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPasswordFile = "/persist/etc/passwd.d/cody";
    openssh.authorizedKeys.keys = authorizedKeys;
  };

  environment.systemPackages = with pkgs; [
    neovim
    htop
    tmux
  ];

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      # FIXME: disable
      PasswordAuthentication = true;
    };
    hostKeys = [
      {
        path = "/persist/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
      {
        path = "/persist/ssh/ssh_host_rsa_key";
        type = "rsa";
        bits = 4096;
      }
    ];
  };

  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];
  networking.firewall.allowedUDPPorts = [ 41641 ];
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  # Retain tailnet management access, but Robin now provides the exit node.
  services.tailscale.useRoutingFeatures = "none";
  services.tailscale.extraSetFlags = [ "--advertise-exit-node=false" ];
  boot.kernel.sysctl."net.ipv4.ip_forward" = 0;
  boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 0;

  zramSwap.enable = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "22.11"; # Did you read the comment?
}
