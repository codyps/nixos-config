# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib, modulesPath, self, ... }:

let
  ssh-auth = (import ../ssh-auth.nix);
  authorizedKeys = ssh-auth.authorizedKeys;
in
{
  imports =
    [
      ./hardware-configuration.nix
      (modulesPath + "/virtualisation/xen-domU.nix")
    ];

  services.logrotate.checkConfig = false;

  boot.zfs.extraPools = [ "tank" ];

  # Without this, boot ends up in grup rescue.
  boot.loader.grub.device = lib.mkForce "/dev/xvda";
  boot.zfs.devNodes = "/dev/disk/by-partuuid";

  # source: https://grahamc.com/blog/erase-your-darlings
  #boot.initrd.postDeviceCommands = lib.mkAfter ''
  #  zfs rollback -r rpool/local/root@blank
  #'';

  # https://discourse.nixos.org/t/zfs-rollback-not-working-using-boot-initrd-systemd/37195/3
  boot.initrd.systemd.enable = lib.mkDefault true;
  boot.initrd.systemd.services.rollback = {
    description = "Rollback root filesystem to a pristine state on boot";
    wantedBy = [
      # "zfs.target"
      "initrd.target"
    ];
    after = [
      "zfs-import-rpool.service"
    ];
    before = [
      "sysroot.mount"
    ];
    path = with pkgs; [
      zfs
    ];
    unitConfig.DefaultDependencies = "no";
    serviceConfig.Type = "oneshot";
    script = ''
      zfs rollback -r rpool/local/root@blank && echo "  >> >> rollback complete << <<"
    '';
  };

  #systemd.services.tailscale-web = {
  #  wantedBy = [
  #    "multi-user.target"
  #  ];
  #  script = ''
  #    ${pkgs.tailscale}/bin/tailscale web
  #  '';
  #};

  #services.cockpit.enable = true;
  #systemd.sockets."cockpit".socketConfig.ListenStream = lib.mkForce "127.0.0.1:${options.services.cockpit.port}";

  boot.initrd.extraFiles."/etc/zfs/zfs-list.cache".source = /persist/var/cache/zfs/zfs-list.cache;
  boot.initrd.extraFiles."/etc/zfs/zpool.cache".source = /persist/var/cache/zfs/zpool.cache;

  swapDevices = [{
    device = "/dev/rpool/local/swap";
  }];

  fileSystems."/persist".neededForBoot = true;

  fileSystems."/var/lib" = {
    device = "/persist/var/lib";
    options = [ "bind" "x-systemd.requires-mounts-for=/persist" ];
    depends = [ "/persist" ];
    neededForBoot = true;
  };

  fileSystems."/var/log" = {
    device = "/persist/var/log";
    options = [ "bind" "x-systemd.requires-mounts-for=/persist" ];
    depends = [ "/persist" ];
    neededForBoot = true;
  };

  fileSystems."/etc/zfs/zfs-list.cache" = {
    device = "/persist/var/cache/zfs/zfs-list.cache";
    options = [ "bind" "x-systemd.requires-mounts-for=/persist" ];
    depends = [ "/persist" ];
    neededForBoot = true;
  };

  fileSystems."/etc/zfs/zpool.cache" = {
    device = "/persist/var/cache/zfs/zpool.cache";
    options = [ "bind" "x-systemd.requires-mounts-for=/persist" ];
    depends = [ "/persist" ];
    neededForBoot = true;
  };

  systemd.tmpfiles.rules = [
    "L /etc/zfs/zfs-list.cache - - - - /persist/var/cache/zfs/zfs-list.cache"
    "L /etc/zfs/zpool.cache - - - - /persist/var/cache/zfs/zpool.cache"
  ];

  environment.etc."machine-id".source = "/persist/etc/machine-id";

  #fileSystems."/var/lib/tailscale" = {
  #  device = "/persist/var/lib/tailscale";
  #  options = [ "bind" ];
  #  noCheck = true;
  #};

  environment.shells = with pkgs; [ zsh ];

  services.zfs.autoScrub = {
    enable = true;
    interval = "monthly";
  };

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

  services.caddy = {
    enable = true;
    #virtualHosts."nix-cache.finch.einic.org".extraConfig = ''
    #  reverse_proxy :5000
    #'';
    #virtualHosts."hydra.finch.einic.org".extraConfig = ''
    #  reverse_proxy :3000
    #'';
    virtualHosts."finch.little-moth.ts.net" = {
      listenAddresses = ["100.112.195.103"];
      extraConfig = ''
        reverse_proxy :8384 {
          # https://docs.syncthing.net/users/faq.html#why-do-i-get-host-check-error-in-the-gui-api
          header_up +Host "localhost"
        }

        forward_auth unix//run/tailscale-nginx-auth/tailscale-nginx-auth.sock {
          uri /auth
          header_up Remote-Addr {remote_host}
          header_up Remote-Port {remote_port}
          header_up Original-URI {uri}
          copy_headers {
            Tailscale-User>X-Webauth-User
            Tailscale-Name>X-Webauth-Name
            Tailscale-Login>X-Webauth-Login
            Tailscale-Tailnet>X-Webauth-Tailnet
            Tailscale-Profile-Picture>X-Webauth-Profile-Picture
          }
        }
      '';
    };
  };

  networking.hostId = "8425e349";
  networking.hostName = "finch";
  networking.useDHCP = false;

  systemd.network = {
    enable = true;
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
  };


  /*
    # system specific details
    networking = {
    useDHCP = false;
    dhcpcd.enable = false;
    useNetworkd = true;

    interfaces.enX0.ipv4.addresses = [ {
      address = "207.90.192.55";
      prefixLength = 24;
    } ];

    interfaces.enX1.ipv6.addresses = [ {
      address = "2602:ffd5:0001:1e7:0000:0000:0000:0001";
      prefixLength = 36;
    } ];

    defaultGateway = "207.90.192.1";
    defaultGateway6 = {
      address = "2602:ffd5:1:100::1";
      #interface = "enX1";
    };
    nameservers = [ "8.8.8.8" ];
    };
  */

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

  services.syncthing = {
    enable = true;
    user = "syncthing";
    dataDir = "/tank/syncthing";
  };

  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 443 80 22000 ];
  networking.firewall.allowedUDPPorts = [ 443 22000 41641 ];
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  services.tailscale.permitCertUid = "caddy";
  services.tailscaleAuth.enable = true;

  systemd.generators."zfs-mount-generator" = "${config.boot.zfs.package}/lib/systemd/system-generator/zfs-mount-generator";
  environment.etc."zfs/zed.d/history_event-zfs-list-cacher.sh".source = "${config.boot.zfs.package}/etc/zfs/zed.d/history_event-zfs-list-cacher.sh";
  systemd.services.zfs-mount.enable = false;

  services.zfs.zed.settings.PATH = lib.mkForce (lib.makeBinPath [
    pkgs.diffutils
    config.boot.zfs.package
    pkgs.coreutils
    pkgs.curl
    pkgs.gawk
    pkgs.gnugrep
    pkgs.gnused
    pkgs.nettools
    pkgs.util-linux
  ]);

  services.udev.extraRules = ''
    KERNEL=="sd[a-z]*[0-9]*|mmcblk[0-9]*p[0-9]*|nvme[0-9]*n[0-9]*p[0-9]*|xvd[a-z]*[0-9]*", ENV{ID_FS_TYPE}=="zfs_member", ATTR{../queue/scheduler}="none"
  '';

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "22.11"; # Did you read the comment?
}
