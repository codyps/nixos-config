{ config, lib, pkgs, ... }:
let
  ssh-auth = (import ../../nixos/ssh-auth.nix);
  authorizedKeys = ssh-auth.authorizedKeys;
in
{
  imports =
    [
      ./hardware-configuration.nix
      ../../modules/zfs.nix
      ../../modules/tailscale-initrd.nix
    ];

  boot.loader.efi.efiSysMountPoint = "/boot.d/0";

  # hack because nixos doesn't have multi-boot partition support for systemd-boot
  boot.loader.systemd-boot.extraInstallCommands = ''
    ${pkgs.rsync}/bin/rsync -ahiv --delete /boot.d/0/ /boot.d/1/
  '';
  # TODO: avoid overwriting the random-seed if we wrote it to the alternate boot partition
  # TODO: tweak systemd-boot-random-seed.service and others to use the other
  # boot partition too. Consider hooking bootctl.
  # TODO: modify efibootmgr to use the other boot partition too.

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  systemd.watchdog.runtimeTime = "30s";

  fileSystems."/persist".neededForBoot = true;

  p.zfs.root-impermenance = {
    enable = true;
    rollback-target = "mainrust/enc/root-tmp@blank";
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
      "/var/lib/samba"
      "/etc/NetworkManager/system-connections"
      { directory = "/var/lib/colord"; user = "colord"; group = "colord"; mode = "u=rwx,g=rx,o="; }
    ];
  };

  # FIXME: if we disable this, then everything breaks becasue we don't every load keys. We'll have to insert our own key loading
  boot.zfs.requestEncryptionCredentials = false;

  boot.initrd = {
    systemd.enable = true;
    systemd.network = config.systemd.network;

    network = {
      enable = true;
      ssh = {
        enable = true;
        authorizedKeys = config.users.users.root.openssh.authorizedKeys.keys;
        # ssh-keygen -t ed25519 -N "" -f /etc/secret/initrd/ssh_host_ed25519_key
        hostKeys = [ "/persist/etc/secret/initrd/ssh_host_ed25519_key" ];
      };
    };

    availableKernelModules = [ "zfs" ];

    # TODO: match required modules
    kernelModules = [ "usb_storage" "igc" "tpm_crb" "zfs" "uas" "nvme" "bonding" ];

    systemd.services."zfs-import-mainrust".wantedBy = [ "initrd.mount" ];
    systemd.services."zfs-import-mainrust".before = [ "initrd.mount" ];

    # FIXME: this currently blocks `tailscale-initrd` from starting, so we just
    # load tailscale _after_ we load this key right now. Not very useful.
    systemd.services."zfs-load-key-mainrust-enc" = {
      description = "Load ZFS encryption key for mainrust/enc";
      wantedBy = [ "sysroot.mount" "create-needed-for-boot-dirs.service" "rollback.service" ];
      before = [ "sysroot.mount" "shutdown.target" "create-needed-for-boot-dirs.service" "rollback.service" ];
      after = [ "zfs-import-mainrust.service" "systemd-ask-password-console.service" ];
      wants = [ "zfs-import-mainrust.service" ];
      conflicts = [ "shutdown.target" ];
      script = ''
        success=false
        tries=4
        while ! $success && [[ $tries -gt 0 ]] ; do
          systemd-ask-password --timeout 0 "Enter ZFS encryption key for mainrust/enc:" | zfs load-key "mainrust/enc" \
           && success=true || tries=$((tries-1))
        done

        $success
      '';

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      unitConfig = {
        DefaultDependencies = false;
      };
    };

    supportedFilesystems.zfs = true;

    # NOTE: this is so tailscale-initrd works
    systemd.contents = {
      # TODO: consider using systemd.mount to configure this instead
      # NOTE: `noauto` is to avoid creating dependencies.
      "/etc/fstab".text = ''
        mainrust/initrd /initrd zfs noauto 0 2
        /initrd/var/lib/tailscale /var/lib/tailscale auto x-systemd.requires-mounts-for=/initrd,bind,X-fstrim.notrim,x-gvfs-hide,noauto 0 2
      '';
    };

    systemd.services.tailscaled.requires = [ "var-lib-tailscale.mount" ];
    systemd.services.tailscaled.after = [ "var-lib-tailscale.mount" ];

    # TODO: encrypt tailscale & ssh host keys using TPM.

    # TODO: move ssh host keys for initrd into same fs as tailscale auth info
    #systemd.contents = {
    #  "/etc/tmpfiles.d/50-ssh-host-keys.conf".text = ''
    #    C /etc/ssh/ssh_host_ed25519_key 0600 - - - /initrd/etc/ssh/ssh_host_ed25519_key
    #    C /etc/ssh/ssh_host_rsa_key 0600 - - - /initrd/etc/ssh/ssh_host_rsa_key
    #  '';
    #};
    #systemd.services.systemd-tmpfiles-setup.before = ["sshd.service"];
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

  networking.useDHCP = false;
  networking.networkmanager.enable = false;
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  networking.firewall.allowedTCPPorts = [ 80 443 ];
  networking.firewall.allowPing = true;

  networking.hostName = "arnold";
  networking.hostId = "5c794628";

  systemd.network =
    let
      bind1-devs = [
        "enp12s0"
        "enp0s31f6"
      ];
    in
    {
      enable = true;
      netdevs."10-bond1" = {
        netdevConfig = {
          Name = "bond1";
          Kind = "bond";
          MACAddress = "none";
        };
        bondConfig = {
          Mode = "802.3ad";
          MIIMonitorSec = "1s";
          LACPTransmitRate = "fast";
          UpDelaySec = "2s";
          DownDelaySec = "8s";
          TransmitHashPolicy = "layer3+4";
        };
      };
      links."10-bond1" = {
        matchConfig = {
          OriginalName = "bond1";
        };

        linkConfig = {
          MACAddressPolicy = "none";
        };
      };
      networks."10-en" = {
        matchConfig = {
          Name = bind1-devs;
        };

        networkConfig = {
          Bond = "bond1";
          LLDP = true;
          EmitLLDP = true;
        };
      };
      networks."20-bond1" = {
        networkConfig = {
          DHCP = "ipv4";
          BindCarrier = bind1-devs;
        };
        matchConfig.Name = "bond1";
      };
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

  users.mutableUsers = false;
  users.users.cody = {
    isNormalUser = true;
    extraGroups = [ "wheel" "tss" ];
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

  security.tpm2 = {
    enable = true;
    pkcs11.enable = true;
    tctiEnvironment.enable = true;
  };

  environment.etc.crypttab = {
    mode = "0600";
    text = ''
      # <volume-name> <encrypted-device> [key-file] [options]
      z10.1   UUID=0ba5ea88-895d-416c-ae69-a011852c1afd /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z8.1    UUID=6d64f9c2-c7c1-44b5-be99-58fdc2251c37 /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z8.2    UUID=d353aef3-4afa-4f8a-9f60-4c233dd3feae /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z10.2   UUID=f5cc9098-95b9-4592-8704-02de317ff4a8 /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z10.3   UUID=999355cf-19c4-43be-aff8-4ba5b30f82c7 /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z8.3    UUID=cb092159-d4cb-402f-a46d-68ecab77120a /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z10.4   UUID=a2c194b0-e0cb-45da-88e2-b363ade7f274 /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z10.5   UUID=531546f7-f110-4507-bf87-56c7323a4be8 /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z8.4    UUID=b1981692-b6d2-4865-8979-dc934a772f50 /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z10.6   UUID=daba9c63-0d4a-41a7-9dd4-16eb50357bea /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z8.5    UUID=b0d47313-23ee-47cb-a452-ba4a65899afe /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z12.0   UUID=bb711a67-822b-4a50-8e52-2664de603c12 /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z12.1   UUID=5f80c366-4ef8-4441-b924-042630b8b5e2 /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z12.2   UUID=9aadb907-6c4a-469b-b795-f15ae210a421 /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z12.3   UUID=43faab20-d5ee-4a0d-9bc8-06515ccd67ad /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z12.4   UUID=03bd7fae-79fb-4f71-9fae-4ee95b39aa77 /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z12.5   UUID=7328ac33-263b-4b35-addd-a5a1934f1cea /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z12.6   UUID=329d228e-ec27-4842-b0ab-a3e029044aba /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z12.7   UUID=8038c355-bc65-4cb1-a823-622f11d6a828 /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z12.8   UUID=71bd51ee-9112-4707-b5e0-6a2be2e83d0a /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z14.0   UUID=327b64ab-b1c0-4494-9b5b-3a6007e9afcc /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z14.1   UUID=4aea7cc3-224f-4ad9-83f4-d687103ad35e /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z14.2   UUID=3fc04e0d-251b-4cec-8172-12c603c58284 /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
      z14.3   UUID=e5b69a87-e02c-4b14-be58-6109488e172a /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
    '';
  };

  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };

  services.samba = {
    enable = true;
    # We need MDNS for timemachine, and plain samba doens't include it.
    # note: theoretically, `pkgs.samba4Full` provides this, but it's not cached
    # so don't bother. Need to set up hydra or similar to auto build & cache
    # this.
    package = pkgs.samba4.override {
      enableMDNS = true;
    };
    openFirewall = true;
    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "arnold";
        "netbios name" = "arnold";
        "security" = "user";

	"disable spoolss" = "Yes";
	"dns proxy" = "No";
	"load printers" = "No";
	"logging" = "file";
	"max log size" = "5120";
	"printcap name" = "/dev/null";
	"registry shares" = "Yes";
	"restrict anonymous" = "2";
	"server multi channel support" = "No";
	"winbind request timeout" = "2";
	"fruit:zero_file_id" = "False";
	"fruit:nfs_aces" = "False";
	"create mask" = "0664";
	"directory mask" = "0775";

        /*
        #"use sendfile" = "yes";
        #"max protocol" = "smb2";
        # note: localhost is the ipv6 localhost ::1
        #"hosts allow" = "10. 100. 192.168. 127.0.0.1 localhost";
        #"hosts deny" = "0.0.0.0/0";
        "guest account" = "nobody";
        "map to guest" = "bad user";

        "server min protocol" = "SMB3_11";
        "server signing" = "mandatory";
        "server smb encrypt" = "required";
        "restrict anonymous" = "2";
        */

        #"vfs objects" = "catia fruit streams_xattr";

        #"fruit:metadata" = "stream";
        #"fruit:resource" = "stream";
        ## requires catia
        #"fruit:encoding" = "native";

        ##"fruit:aapl" = "yes";
        ##"fruit:veto_appledouble" = "no";
        ##"fruit:posix_rename" = "yes";
        #"fruit:zero_file_id" = "False";

        #"domain master" = "yes";
        #"guest ok" = "no";
        #"create mask" = "0664";
        #"directory mask" = "0775";


        /*
	"bind interfaces only" = "Yes";
	"disable spoolss" = "Yes";
	"dns proxy" = "No";
	"load printers" = "No";
	"logging" = "file";
	"max log size" = "5120";
	"passdb backend" = "tdbsam:/var/run/samba-cache/private/passdb.tdb";
	"printcap name" = "/dev/null";
	"registry shares" = "Yes";
	"restrict anonymous" = "2";
	"server multi channel support" = "No";
	"server string" = "TrueNAS Server";
	"winbind request timeout" = "2";
	"idmap config * : range" = "90000001 - 100000000";
	"fss:prune stale" = "True";
	"rpc_daemon:fssd" = "fork";
	"fruit:zero_file_id" = "False";
	"fruit:nfs_aces" = "False";
	"idmap config * : backend" = "tdb";
	"create mask" = "0664";
	"directory mask" = "0775";
        */
      };
      "tank" = {
	"ea support" = "No";
        "path" = "/tank";
        "writable" = "yes";
        "valid users" = "cody";
        "browseable" = "yes";
      };
      "timemachine" = {
        "path" = "/tank/backup/timemachine4";
        "valid users" = "cody";
        /*
        "guest ok" = "no";
        "writeable" = "yes";
        "fruit:time machine" = "yes";
        "browseable" = "yes";
        "fruit:aapl" = "yes";
	"durable handles" = "yes";
	"kernel oplocks" = "no";
	"kernel share modes" = "no";
	"posix locking" = "no";
        */

	"ea support" = "No";
	"posix locking" = "No";
	"read only" = "No";
	"smbd max xattr size" = "2097152";
	"vfs objects" = "catia fruit streams_xattr";
        #"zfs_core:zfs_auto_create" = "true";
        #"tn:vuid" = "e8f2fd79-7e7e-4ecb-adb3-d8517db947cb";
	"fruit:time machine max size" = "0";
	"fruit:time machine" = "True";
	"fruit:resource" = "stream";
	"fruit:metadata" = "stream";
        "nfs4:chown" = "True";
        #"tn:home" = "False";
        #"tn:path_suffix" = "%U";
        #"tn:purpose" = "ENHANCED_TIMEMACHINE";



      };
    };
  };

  systemd.services.caddy = {
    serviceConfig = {
      EnvironmentFile = "/persist/etc/default/caddy";
      RuntimeDirectory = "caddy";
    };
  };

  services.caddy = {
    enable = true;
    package = pkgs.caddy.withPlugins {
      plugins = [
        "github.com/caddy-dns/cloudflare@v0.0.0-20240703190432-89f16b99c18e"
        "github.com/caddyserver/cache-handler@v0.14.0"
        "github.com/darkweak/storages/badger/caddy@v0.0.10"
        "github.com/WeidiDeng/caddy-cloudflare-ip@v0.0.0-20231130002422-f53b62aa13cb"
      ];
      hash = "sha256-m6SVqy9ks4mvdcgqs+YD6MeE98WjGga25zbrOjPBMKs=";
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

    virtualHosts."*.arnold.einic.org, arnold.einic.org" = {
      extraConfig = ''
        @free-games-claimer host free-games-claimer.arnold.einic.org
        route @free-games-claimer {
          import /persist/etc/secret/caddy-auth
          reverse_proxy :6080 {
                  header_up +Host "localhost"
          }
        }

        @rslsync host rslsync.arnold.einic.org
        route @rslsync {
          import /persist/etc/secret/caddy-auth
          reverse_proxy :8389
        }

        @minio-console host minio-console.arnold.einic.org
        route @minio-console {
          import /persist/etc/secret/caddy-auth
          reverse_proxy :9198
        }

        @minio host minio.arnold.einic.org
        route @minio {
          import /persist/etc/secret/caddy-auth
          reverse_proxy :9199
        }

        @syncthing host syncthing.arnold.einic.org
        route @syncthing {
          import /persist/etc/secret/caddy-auth

          reverse_proxy :8384 {
                  # https://docs.syncthing.net/users/faq.html#why-do-i-get-host-check-error-in-the-gui-api
                  header_up +Host "localhost"
          }
        }

        @sonarr host sonarr.arnold.einic.org
        route @sonarr {
                reverse_proxy :8989
        }

        @komga host komga.arnold.einic.org
        route @komga {
                reverse_proxy [::1]:25600
        }

        @jellyfin host jellyfin.arnold.einic.org
        route @jellyfin {
                reverse_proxy :8096 {
                        # https://github.com/jellyfin/jellyfin/issues/5575
                        header_up +Host "localhost"
                }
        }

        @radarr host radarr.arnold.einic.org
        route @radarr {
                reverse_proxy :7878
        }

        @arnold host arnold.einic.org
        route @arnold {
                @secure {
                        not path /~*
                        #path /tank/*
                        #path /games/*
                        not path /audiobooks
                        not path /audiobooks/*
                        not path /switch
                        not path /switch/*
                }

                @switch {
                        path /switch
                        path /switch/*
                }

                import /persist/etc/secret/caddy-auth-2

                redir /jackett /jackett/
                reverse_proxy /jackett/* http://127.0.0.1:9117

                redir /tank /tank/
                handle_path /tank/* {
                        file_server browse {
                                root /tank
                        }
                }

                redir /switch /switch/
                handle_path /switch/* {
                        file_server browse {
                                root /tank/DATA/games/console/nintendo-switch
                        }
                }

                redir /audiobooks /audiobooks/
                handle_path /audiobooks/* {
                        file_server browse {
                                root /tank/DATA/audiobooks
                        }
                }

                redir /games /games/
                handle_path /games/* {
                        file_server browse {
                                root /tank/DATA/games
                        }
                }

                @user_html {
                        path_regexp user '^/~([^/]+)'
                }

                route @user_html {
                        uri strip_prefix {re.user.0}
                        file_server browse {
                                root /home/{re.user.1}/public_html/
                        }
                }

                root * /srv/http
                templates
                file_server
        }

        root * /srv/http

        encode zstd gzip

        log {
                output file /var/log/caddy/access.log
        }
      '';
    };
  };

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
    extraServiceFiles = {
      smb = ''
        <?xml version="1.0" standalone='no'?><!--*-nxml-*-->
        <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
        <service-group>
          <name replace-wildcards="yes">%h</name>
          <service>
            <type>_smb._tcp</type>
            <port>445</port>
          </service>
        </service-group>
      '';
    };
  };

  system.stateVersion = "24.11";
}
