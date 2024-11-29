# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib, modulesPath, self, ... }:

let
  ssh-auth = (import ../../nixos/ssh-auth.nix);
  authorizedKeys = ssh-auth.authorizedKeys;
in
{
  imports =
    [
      ./hardware-configuration.nix
      (modulesPath + "/virtualisation/xen-domU.nix")
    ];

  services.logrotate.checkConfig = false;

  system.autoUpgrade.enable = lib.mkForce true;

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


  systemd.services.caddy.serviceConfig.EnvironmentFile = "/persist/etc/default/caddy";
  services.caddy = {
    enable = true;
    package = (pkgs.callPackage ../../nixpkgs/overlays/pkgs/caddy/package.nix { }).withPlugins {
      caddyModules = [
        { repo = "github.com/caddy-dns/cloudflare"; version = "89f16b99c18ef49c8bb470a82f895bce01cbaece"; }
        { repo = "github.com/caddyserver/cache-handler"; version = "283ea9b5bf192ff9c98f0b848c7117367655893f"; } # v0.14.0
        { repo = "github.com/darkweak/storages/badger/caddy"; version = "0d6842b38ab6937af5a60adcf54d8955b5bbe6fc"; } # v0.0.10
        { repo = "github.com/WeidiDeng/caddy-cloudflare-ip"; version = "f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5"; } # head of main
      ];
      vendorHash = "sha256-Z80OP4fMele2kITxJkKKHGe/jbhCIAl43rp+FEYnvoE=";
    };

    globalConfig = ''
      cache

      acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}

      servers {
        trusted_proxies cloudflare {
          interval 12h
          timeout 15s
        }
      }
    '';

    virtualHosts."*.einic.org" = {
      extraConfig = ''
        @audiobooks host audiobooks.einic.org
        handle @audiobooks {
          root /tank/libation/data/Books
          file_server browse
        }

        @audiobookshelf host audiobookshelf.einic.org
        handle @audiobookshelf {
          reverse_proxy http://localhost:8917
        }

        handle {
          abort
        }
      '';

    };

    virtualHosts."finch.little-moth.ts.net" = {
      listenAddresses = [ "100.112.195.103" ];
      extraConfig = ''
        root /srv

        file_server /roms/* {
          root /tank/syncthing/Roms
          browse {
             reveal_symlinks
          }
        }

        handle_path /syncthing/* {
          reverse_proxy http://localhost:8384 {
              # https://docs.syncthing.net/users/reverseproxy.html
              #header_up Host {upstream_hostport}
              # https://docs.syncthing.net/users/faq.html#why-do-i-get-host-check-error-in-the-gui-api
              header_up +Host "localhost"
          }
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
  services.tailscaleAuth = {
    enable = true;
    user = "caddy";
    group = "caddy";
  };

  systemd.generators."zfs-mount-generator" = "${config.boot.zfs.package}/lib/systemd/system-generator/zfs-mount-generator";
  environment.etc."zfs/zed.d/history_event-zfs-list-cacher.sh".source = "${config.boot.zfs.package}/etc/zfs/zed.d/history_event-zfs-list-cacher.sh";
  systemd.services.zfs-mount.enable = false;

  virtualisation.oci-containers.containers = {
    libation = {
      image = "docker.io/rmcrackan/libation:latest";
      volumes = [
        "/tank/libation/data:/data"
        "/tank/libation/config:/config"
        "/tank/libation/tmp:/tmp"
        #"/var/lib/libation/data:/data"
        #"/var/lib/libation/config:/config"
      ];
      environment = {
        SLEEP_TIME = "1h";
      };
      labels = {
        "io.containers.autoupdate" = "registry";
      };
    };
  };

  # oci-containers can't handle running as a user. See:
  # https://github.com/NixOS/nixpkgs/issues/259770
  #systemd.services.podman-libation.serviceConfig = {
  #  User = "libation";
  #  Home = "/tank/libation";
    #DynamicUser = true;
    #StateDirectory = "libation";
  #};
  #users.users.libation = {
  #  isSystemUser = true;
  #  group = "libation";
  #};
  #users.groups.libation = {};

  virtualisation.podman = {
    enable = true;
    autoPrune.enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  services.audiobookshelf = {
    enable = true;
    port = 8917;
  };

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
