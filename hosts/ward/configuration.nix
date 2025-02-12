{ config, lib, pkgs, ... }:
let
  ssh-auth = (import ../../nixos/ssh-auth.nix);
  authorizedKeys = ssh-auth.authorizedKeys;
in
{
  imports =
    [
      ./hardware-configuration.nix
      ../../nixos-modules/all-modules.nix
    ];

  boot.kernelParams = [ "ip=dhcp" ];
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  systemd.watchdog.runtimeTime = "30s";

  # hashedPasswordFile reads from this
  fileSystems."/persist".neededForBoot = true;

  p.zfs.root-impermenance = {
    enable = true;
    rollback-target = "ward/temp/root@blank";
  };

  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/bluetooth"
      "/var/lib/nixos"
      "/var/lib/upower"
      "/var/lib/tailscale"
      "/var/lib/systemd/coredump"
      "/var/lib/audiobookshelf"
      "/etc/NetworkManager/system-connections"
      { directory = "/var/lib/colord"; user = "colord"; group = "colord"; mode = "u=rwx,g=rx,o="; }
    ];
  };

  boot.initrd = {
    systemd.enable = true;

    network = {
      enable = true;
      ssh = {
        enable = true;
        authorizedKeys = authorizedKeys;
        hostKeys = [ "/persist/etc/secret/initrd/ssh_host_ed25519_key" ];
      };
    };

    kernelModules = [ "usb_storage" "igc" "tpm_crb" ];

    luks.devices = {
      luksroot = {
        device = "/dev/disk/by-uuid/b8de49f4-4952-4a22-8d8c-f616b77e982e";
        allowDiscards = true;
        keyFileSize = 4096;
        keyFile = "/dev/disk/by-id/usb-Samsung_Type-C_0396123100002458-0:0-part5";
      };
    };
  };

  programs.nix-ld.enable = true;

  virtualisation.docker.rootless = {
    enable = true;
    setSocketVariable = true;
  };

  virtualisation.podman = {
    enable = true;
    autoPrune.enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  services.hydra = {
    enable = true;
    hydraURL = "https://ward.little-moth.ts.net/hydra";
    notificationSender = "hydra@localhost"; # e-mail of hydra service
    # a standalone hydra will require you to unset the buildMachinesFiles list to avoid using a nonexistant /etc/nix/machines
    buildMachinesFiles = [ ];
    # you will probably also want, otherwise *everything* will be built from scratch
    useSubstitutes = true;
  };

  services.harmonia = {
    enable = true;
    signKeyPaths = [
      "/persist/etc/nix-binary-cache/binary-cache.secret"
    ];
    settings.bind = "[::1]:8916";
  };

  services.audiobookshelf = {
    enable = true;
    port = 8917;
  };

  #services.atticd = {
  #  enable = true;
  #  credentialsFile = "/persist/etc/atticd.env";
  #  settings = {
  #    listen = "[::1]:8915";
  #  }
  #};

  #services.nix-serve = {
  #  enable = true;
  #  secretKeyFile = "/persist/etc/nix-serve/cache-priv-key.pem";
  #};

  systemd.services.caddy.serviceConfig.EnvironmentFile = "/persist/etc/default/caddy";
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

        @arnold host arnold.einic.org *.arnold.einic.org
        handle @arnold {
          reverse_proxy https://192.168.6.10
        }

        @audiobooks host audiobooks.einic.org
        handle @audiobooks {
          root /ward/keep/libation/data/Books
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

    virtualHosts."*.ward.einic.org" = {
      extraConfig = ''
        root /srv

        @zd621 host zd621.ward.einic.org
        handle @zd621 {
          import /persist/etc/caddy-auth-config
          # D7J211001302.bed.einic.org
          reverse_proxy http://192.168.6.192 {
            header_up Authorization "Basic YWRtaW46MTIzNA=="
          }
        }

        #@archivebox host archivebox.ward.einic.org
        #handle @archivebox {
        #  reverse_proxy http://localhost:8000
        #}

        @audiobookshelf host audiobookshelf.ward.einic.org
        handle @audiobookshelf {
          reverse_proxy http://localhost:8917
        }

        @audiobooks host audiobooks.ward.einic.org
        handle @audiobooks {
          root /ward/keep/libation/data/Books
          file_server browse
        }

        handle {
          abort
        }
      '';
    };

    # NOTE: merged these because we have the same listenaddress and it seemed to fail with 2 seperate ones with the same address
    virtualHosts."ward.little-moth.ts.net, *.ward.ts.einic.org" = {
      listenAddresses = [ "100.115.212.42" ];
      # NOTE: nixos can't handle virtualHosts with multiple hosts, so we have to set logFormat manually
      logFormat = "output file /var/log/caddy/ward.ts.einic.org.log";
      extraConfig = ''
        root /srv

        @gramps host gramps.ward.ts.einic.org
        handle @gramps {
          reverse_proxy http://localhost:5000
        }

        @zd621_ts host zd621.ward.ts.einic.org
        handle @zd621_ts {
          # D7J211001302.bed.einic.org
          reverse_proxy http://192.168.6.192 {
            header_up Authorization "Basic YWRtaW46MTIzNA=="
          }
        }

        @archivebox host archivebox.ward.ts.einic.org
        handle @archivebox {
          reverse_proxy http://localhost:8000
        }

        @tsnet host ward.little-moth.ts.net
        handle @tsnet {
          redir /nix-cache /nix-cache/ 301
          handle_path /nix-cache/* {
            cache {
              badger {
                path /ward/keep/nix-cache
              }

              key {
                disable_host
                disable_scheme
              }

              ttl 30000h
              default_cache_control no-store
            }
            reverse_proxy https://cache.nixos.org {
              header_up Host {upstream_hostport}

              @ok status 200 302
              handle_response @ok {
                header Cache-Control "public, immutable"
                copy_response
              }
            }
          }

          redir /harmonia /harmonia/ 301
          handle_path /harmonia/* {
            reverse_proxy http://localhost:8916 {
            }
          }

          redir /hydra /hydra/ 301
          handle_path /hydra/* {
            reverse_proxy http://localhost:${toString config.services.hydra.port} {
              header_up Host {upstream_hostport}
              header_up X-Request-Base /hydra
            }
          }

          redir /audiobooks /audiobooks/ 301
          handle_path /audiobooks/* {
            root /ward/keep/libation/data/Books
            file_server browse
          }

          redir /grafana /grafana/ 301
          handle_path /grafana/* {
            reverse_proxy http://${toString config.services.grafana.settings.server.http_addr}:${toString config.services.grafana.settings.server.http_port}
          }
        }

        # return 404 for all other requests
        handle {
          abort
        }
      '';
    };
  };

  virtualisation.oci-containers.containers = {
    archivebox = {
      image = "docker.io/archivebox/archivebox:dev";
      ports = [ "127.0.0.1:8000:8000" ];
      volumes = [
        "/ward/keep/archivebox:/data"
      ];
      labels = {
        "io.containers.autoupdate" = "registry";
      };
      environment = {
        CSRF_TRUSTED_ORIGINS = "https://archivebox.ward.ts.einic.org";
      };
      extraOptions = [
        "--pids-limit=-1"
        "--cpus=4"
        "--cpu-shares=512"
        "--memory=32G"
      ];
    };

    libation = {
      image = "docker.io/rmcrackan/libation:latest";
      volumes = [
        "/ward/keep/libation/data:/data"
        "/ward/keep/libation/config:/config"
      ];
      environment = {
        SLEEP_TIME = "2h";
      };
      labels = {
        "io.containers.autoupdate" = "registry";
      };
    };
  };

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "127.0.0.1";
        http_port = 3001;
        domain = "ward.little-moth.ts.net";
        root_url = "https://ward.little-moth.ts.net/grafana/";
      };
    };
  };

  services.influxdb = {
    enable = true;
    dataDir = "/persist/var/lib/influxdb";
    extraConfig = {
      http = {
        bind-address = "[::1]:8086";
      };
    };
  };

  networking.useDHCP = false;
  networking.networkmanager.enable = false;
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  networking.firewall.allowedTCPPorts = [ 80 443 ];

  networking.hostName = "ward";
  networking.hostId = "5c794628";

  systemd.network = {
    enable = true;
    networks."10-enp3s0.network" = {
      networkConfig.DHCP = "ipv4";
      matchConfig.Name = "enp3s0";
      # prioritize the local network directly instead of using tailscale
      routingPolicyRules = [
        {
          To = "192.168.6.0/24";
          Priority = 2500;
        }
      ];
    };
    wait-online.anyInterface = true;
  };

  services.cloudflared = {
    enable = true;
    tunnels."3a303175-5ce5-459c-b1fb-d2cf9cbcd5b2" = {
      credentialsFile = "/persist/etc/cloudflared/3a303175-5ce5-459c-b1fb-d2cf9cbcd5b2.json";
      default = "http_status:404";
    };
  };

  # https://github.com/quic-go/quic-go/wiki/UDP-Buffer-Sizes
  boot.kernel.sysctl."net.core.rmem_max" = 7500000;
  boot.kernel.sysctl."net.core.wmem_max" = 7500000;

  services.tailscale.permitCertUid = "caddy";
  services.tailscaleAuth = {
    enable = true;
    user = "caddy";
    group = "caddy";
  };

  time.timeZone = "America/New_York";

  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  #   useXkbConfig = true; # use xkb.options in tty.
  # };

  # Enable the X11 windowing system.
  services.xserver.enable = true;


  # Enable the GNOME Desktop Environment.
  services.xserver.desktopManager.gnome.enable = true;
  services.xserver.displayManager.gdm.enable = true;
  services.xserver.displayManager.gdm.autoSuspend = false;
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.login1.suspend" ||
            action.id == "org.freedesktop.login1.suspend-multiple-sessions" ||
            action.id == "org.freedesktop.login1.hibernate" ||
            action.id == "org.freedesktop.login1.hibernate-multiple-sessions")
        {
            return polkit.Result.NO;
        }
    });
  '';

  environment.etc."gdm/greeter.dconf-defaults" = {
    text = ''
      [org/gnome/settings-daemon/plugins/power]
      sleep-inactive-ac-type='nothing'
      sleep-inactive-ac-timeout=0
    '';
  };


  # Configure keymap in X11
  # services.xserver.xkb.layout = "us";
  # services.xserver.xkb.options = "eurosign:e,caps:escape";

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound.
  # sound.enable = true;
  # hardware.pulseaudio.enable = true;

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  users.mutableUsers = false;
  users.users.cody = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    packages = with pkgs; [
      firefox
    ];
    hashedPasswordFile = "/persist/etc/secret/cody.pass";
    openssh.authorizedKeys.keys = authorizedKeys;
  };

  users.users.root = {
    hashedPasswordFile = "/persist/etc/secret/root.pass";
    openssh.authorizedKeys.keys = authorizedKeys;
  };

  environment.systemPackages = with pkgs; [
    neovim
    linuxPackages.perf
    git
    curl
    htop
  ];

  programs.mtr.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = true;
    };
    hostKeys = [
      {
        path = "/persist/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
      {
        path = "/persist/etc/ssh/ssh_host_rsa_key";
        type = "rsa";
        bits = 4096;
      }
    ];
  };

  services.tailscale.enable = true;

  services.avahi = {
    enable = true;
    openFirewall = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      domain = true;
      hinfo = true;
      userServices = true;
      workstation = true;
    };
  };

  zramSwap.enable = true;

  system.stateVersion = "23.11";
}
