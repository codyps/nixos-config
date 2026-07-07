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
      ../../nixos-modules/all-modules.nix
      ./disko.nix
    ];

  services.logrotate.checkConfig = false;

  system.autoUpgrade.enable = lib.mkForce false;
  nix.optimise.automatic = lib.mkForce false;
  nix.gc.automatic = lib.mkForce false;

  # mkDefault so it is overridden when building the vm
  boot.zfs.devNodes = lib.mkDefault "/dev/disk/by-partuuid";

  # https://discourse.nixos.org/t/zfs-rollback-not-working-using-boot-initrd-systemd/37195/3
  boot.initrd.systemd.enable = true;

  p.zfs.root-impermenance = {
    enable = true;
    rollback-target = "robin/root@blank";
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

  systemd.services.caddy = let
    mounts = [ "var-lib-libation.mount" "var-lib-syncthing.mount" ];
  in {
    serviceConfig = {
      EnvironmentFile = "/persist/etc/default/caddy";
      RuntimeDirectory = "caddy";
    };

    requires = mounts;
    after = mounts;
  };

  services.caddy = {
    enable = true;
    package = pkgs.caddyFull;

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
          root /var/lib/libation/data/
          file_server browse
        }

        @audiobookshelf host audiobookshelf.einic.org
        handle @audiobookshelf {
          reverse_proxy http://127.0.0.1:8917
        }

        handle {
          abort
        }
      '';
    };
  };

  networking.hostId = "4129717c";
  networking.hostName = "robin";
  networking.useDHCP = false;

  systemd.network = {
    enable = true;
    wait-online.anyInterface = true;

    networks."10-en" = {
      matchConfig.Name = "en*";
      networkConfig = {
        DHCP = "ipv4";
        DNSSEC = "no";
      };
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

  services.syncthing = {
    enable = true;
    dataDir = "/var/lib/syncthing";
    overrideDevices = false;
    settings = {
      devices = {
        "u3" = { id = "SYFXMYB-T4PKQ3E-IQHWO7R-LDHJ7LL-P7BTPBR-NRDS6CG-3NB7W72-ZCATPAW"; };
      };
    };
  };

  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 443 80 22000 ];
  networking.firewall.allowedUDPPorts = [ 443 22000 41641 ];
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  # enable tailscale exit
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;

  services.tailscale.permitCertUid = "caddy";

  #virtualisation.oci-containers.containers = {
    #libation = {
    #  image = "docker.io/rmcrackan/libation:latest";
    #  autoStart = false;
    #  volumes = [
    #    "/tank/libation/data:/data"
    #    "/tank/libation/config:/config"
    #    "/tank/libation/tmp:/tmp"
    #    #"/var/lib/libation/data:/data"
    #    #"/var/lib/libation/config:/config"
    #  ];
    #  labels = {
    #    "io.containers.autoupdate" = "registry";
    #  };
    #};

    #storyteller = {
    #  image = "registry.gitlab.com/smoores/storyteller:latest";
    #  volumes = [
    #    "/tank/storyteller/data:/data"
    #    "/tank/storyteller/secret:/run/secret"
    #  ];
    #  environment = {
    #    STORYTELLER_SECRET_KEY_FILE = "/run/secret/key";
    #  };
    #  ports = [
    #    "127.0.0.1:8918:8001"
    #  ];
    #  labels = {
    #    "io.containers.autoupdate" = "registry";
    #  };
    #};
  #};

  #systemd.services.podman-libation =
  #  let
  #    mounts = [
  #      "tank-libation.mount"
  #      "tank-books-kindle.mount"
  #      "tank-books-personal.mount"
  #    ];
  #  in
  #  {
  #    serviceConfig = {
  #      Type = lib.mkForce "oneshot";
  #      Restart = lib.mkForce "on-failure";
  #    };
  #    after = mounts;
  #    requires = mounts;
  #  };

  #systemd.timers.podman-libation = {
  #  wantedBy = [ "timers.target" ];
  #  timerConfig = {
  #    Persistent = true;
  #    OnCalendar = "hourly";
  #    AccuracySec = "30m";
  #    RandomizedDelaySec = "20m";
  #  };
  #};

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

  #virtualisation.podman = {
  #  enable = true;
  #  autoPrune.enable = true;
  #  defaultNetwork.settings.dns_enabled = true;
  #};

  #services.audiobookshelf = {
  #  package = pkgs.audiobookshelf-headless;
  #  enable = true;
  #  port = 8917;
  #};

  zramSwap.enable = true;

  system.stateVersion = "26.10";
}
