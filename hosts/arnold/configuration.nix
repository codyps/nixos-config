{ config, lib, pkgs, ... }:
let
  ssh-auth = (import ../../nixos/ssh-auth.nix);
  authorizedKeys = ssh-auth.authorizedKeys;
  komgaPort = 10100;
  kavitaPort = 10101;
  komfPort = 10102;
  calibreWebAutomatedPort = 10103;

  # FIXME: prowlarr has these set internally, we need to tweak prowlarr to use
  # these values
  sonarr-port = 8989;
  radarr-port = 7878;
  readarr-port = 8787;
  prowlarr-port = 9696;

  # NOTE: because `transmission-remote` looks at localhost:9091 by default, if
  # we change this we should wrap `transmission-remote`.
  transmissionPort = 9091;

  pia-wg-util = pkgs.writeShellApplication {
    name = "pia-wg-util";
    text = builtins.readFile ../../scripts/pia-wg-util.sh;
    runtimeInputs = [ pkgs.iproute2 pkgs.wireguard-tools pkgs.curl pkgs.jq pkgs.coreutils pkgs.iputils ];
  };
in
{
  imports =
    [
      ./hardware-configuration.nix
      ../../nixos-modules/all-modules.nix
      ../../modules/tailscale-initrd.nix
    ];

  boot.loader.efi.efiSysMountPoint = "/boot.d/0";

  boot.zfs.extraPools = [ "tank" ];

  # hack because nixos doesn't have multi-boot partition support for systemd-boot
  boot.loader.systemd-boot.extraInstallCommands = ''
    ${pkgs.rsync}/bin/rsync -ahiq --delete /boot.d/0/ /boot.d/1/
  '';
  # TODO: avoid overwriting the random-seed if we wrote it to the alternate boot partition
  # TODO: tweak systemd-boot-random-seed.service and others to use the other
  # boot partition too. Consider hooking bootctl.
  # TODO: modify efibootmgr to use the other boot partition too.

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  hardware.cpu.intel.updateMicrocode = true;

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
      "/var/lib/komga"
      "/var/lib/kavita"
      "/var/lib/transmission"
      "/var/lib/jellyfin"
      "/var/lib/pia-wg"
      "/var/lib/sabnzbd"
      "/var/lib/containers"
      "/var/lib/systemd"
      "/var/lib/caddy"
      "/var/lib/readarr"
      "/var/lib/private/prowlarr"
      "/var/lib/private/recyclarr"
      "/var/lib/sonarr"
      "/var/lib/radarr"
      "/var/lib/uptimed"
      "/var/cache/jellyfin"
      "/var/db"
      "/etc/NetworkManager/system-connections"
      { directory = "/var/lib/colord"; user = "colord"; group = "colord"; mode = "u=rwx,g=rx,o="; }
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/private 0700 root root"
  ];

  # FIXME: if we disable this, then everything breaks becasue we don't every load keys. We'll have to insert our own key loading
  boot.zfs.requestEncryptionCredentials = false;

  sops.age.sshKeyPaths = [
    "/persist/etc/ssh/ssh_host_ed25519_key"
  ];

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
  networking.firewall.trustedInterfaces = [ "tailscale0" "podman0" ];
  networking.firewall.allowedTCPPorts = [
    # caddy
    80
    443
    # syncthing
    22000
  ];

  networking.firewall.allowedUDPPorts = [
    # jellyfin
    1900
    7359
    # syncthing
    21027
  ];

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
        # prioritize the local network directly instead of using tailscale
        routingPolicyRules = [
          {
            To = "192.168.6.0/24";
            Priority = 2500;
          }
        ];

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
      [org.gnome.settings-daemon.plugins.power]
      sleep-inactive-ac-type='nothing'
    '';
  };

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

  users.users.securitycamera = {
    hashedPasswordFile = "/persist/etc/secret/securitycamera.pass";
    openssh.authorizedKeys.keys = authorizedKeys;
    isNormalUser = true;
  };

  environment.systemPackages = with pkgs; [
    neovim
    linuxPackages.perf
    git
    curl
    htop
    wireguard-tools
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
      i01     UUID=72bf8068-6563-4f66-babc-4e337922b4ed /persist/etc/secret/luks1 discard,no-read-workqueue,no-write-workqueue,same-cpu-crypt
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
        "mdns name" = "mdns";
      };
      "windows-fh" = {
        "ea support" = "No";
        "path" = "/tank/backup/windows/fh";
        "writable" = "yes";
        "valid users" = "cody";
        "browseable" = "yes";
      };
      "tank" = {
        "ea support" = "No";
        "path" = "/tank";
        "writable" = "yes";
        "valid users" = "cody";
        "browseable" = "yes";
      };
      "securitycamera" = {
        "ea support" = "No";
        "path" = "/tank/DATA/securitycamera";
        "writable" = "yes";
        "valid users" = "securitycamera";
        "browseable" = "yes";
      };
      "timemachine" = {
        "path" = "/tank/backup/timemachine4";
        "valid users" = "cody";

        "ea support" = "No";
        "posix locking" = "No";
        "read only" = "No";
        "smbd max xattr size" = "2097152";
        "vfs objects" = "catia fruit streams_xattr";
        "fruit:time machine max size" = "0";
        "fruit:time machine" = "True";
        "fruit:resource" = "stream";
        "fruit:metadata" = "stream";
        "nfs4:chown" = "True";
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

    virtualHosts."*.arnold.einic.org, arnold.einic.org" = {
      # NOTE: nixos can't handle virtualHosts with multiple hosts, so we have to set logFormat manually
      logFormat = "output file /var/log/caddy/arnold.einic.org.log";
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
          reverse_proxy :${toString sonarr-port}
        }

        @komga host komga.arnold.einic.org
        route @komga {
          reverse_proxy 127.0.0.1:${toString komgaPort}
        }

        @kavita host kavita.arnold.einic.org
        route @kavita {
          reverse_proxy 127.0.0.1:${toString kavitaPort}
        }

        @jellyfin host jellyfin.arnold.einic.org
        route @jellyfin {
          reverse_proxy :8096 {
            # https://github.com/jellyfin/jellyfin/issues/5575
            header_up +Host "localhost"
          }
        }

        @transmission host transmission.arnold.einic.org
        route @transmission {
          import /persist/etc/secret/caddy-auth
          reverse_proxy 127.0.0.1:${toString transmissionPort}
        }

        @calibre-web-automated host calibre-web-automated.arnold.einic.org
        route @calibre-web-automated {
          reverse_proxy 127.0.0.1:${toString calibreWebAutomatedPort}
        }

        @prowlarr host prowlarr.arnold.einic.org
        route @prowlarr {
          import /persist/etc/secret/caddy-auth
          reverse_proxy :${toString prowlarr-port}
        }

        @readarr host readarr.arnold.einic.org
        route @readarr {
          import /persist/etc/secret/caddy-auth
          reverse_proxy :${toString readarr-port}
        }

        @radarr host radarr.arnold.einic.org
        route @radarr {
          import /persist/etc/secret/caddy-auth
          reverse_proxy :${toString radarr-port}
        }

        @sabnzbd host sabnzbd.arnold.einic.org
        route @sabnzbd {
          import /persist/etc/secret/caddy-auth
          reverse_proxy :8080
        }

        @qbittorrent host qbittorrent.arnold.einic.org
        route @qbittorrent {
          import /persist/etc/secret/caddy-auth
          reverse_proxy :${toString config.services.qbittorrent.webui-port}
        }
        
        root * /srv/http

        encode zstd gzip
      '';
    };
  };

  services.syncthing = {
    enable = true;
    dataDir = "/tank/DATA/syncthing";
  };

  services.avahi = {
    enable = true;
    openFirewall = true;
    nssmdns4 = true;
    allowInterfaces = [ "bond0" ];
    publish = {
      enable = true;
      addresses = true;
      domain = true;
      hinfo = true;
      userServices = true;
      workstation = true;
    };
    extraServiceFiles = {
      /*
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
      */
    };
  };

  # FIXME: nixos places the komga config in `/var/lib/komga/application.yml`,
  # which we persist in a bind mount. This makes initial startup break because
  # the `application.yml` gets put in place before the bind mount is executed.
  # And generally mixing nixos created config and application db stuff is a bad
  # idea. Look at changing the path used for the configuration file.
  # FIXME: changing the settings doesn't trigger a restart of komga, meaning
  # port/address changes don't take effect until a manual restart.
  services.komga = {
    enable = true;
    settings = {
      server = {
        port = komgaPort;
      };
    };
  };

  systemd.services.podman-komf.serviceConfig = {
    EnvironmentFile = "/persist/etc/default/komf";
  };

  virtualisation.oci-containers.containers.komf = {
    image = "sndxr/komf:latest";
    ports = [ "127.0.0.1:${toString komfPort}:${toString komfPort}" ];
    environment = {
      KOMF_SERVER_PORT = toString komfPort;
      KOMF_KOMGA_BASE_URI = "http://host.containers.internal:${toString komgaPort}";
      KOMF_KAVITA_BASE_URI = "http://host.containers.internal:${toString kavitaPort}";
      KOMF_LOG_LEVEL = "INFO";
    };
    volumes = [
      "/persist/var/lib/komf:/config"
    ];
  };

  users.users.calibre-web-automated = {
    description = "Calibre Web Automated";
    isSystemUser = true;
    group = "calibre-web-automated";
    # FIXME: if we could set environment variables in the container dynamically
    # (ie: at container creation time) we wouldn't need static uid/gid, but
    # nixos doesn't support that right now.
    uid = 988;
  };
  users.groups.calibre-web-automated = {
    gid = 982;
  };

  virtualisation.oci-containers.containers.calibre-web-automated = {
    image = "crocodilestick/calibre-web-automated:latest";
    ports = [ "127.0.0.1:${toString calibreWebAutomatedPort}:8083" ];
    environment = {
      TZ = "America/New_York";

      PUID = toString config.users.users.calibre-web-automated.uid;
      PGID = toString config.users.groups.calibre-web-automated.gid;
    };
    volumes = [
      "/persist/var/lib/calibre-web-automated:/config"
      "/tank/DATA/calibre-library:/calibre-library"
      "/tank/TMP/ingest/cwa-book-ingest:/cwa-book-ingest"
    ];
  };

  services.kavita = {
    enable = true;
    tokenKeyFile = "/persist/etc/kavita/tokenKeyFile";
    settings = {
      Port = kavitaPort;
    };
  };

  services.jellyfin.enable = true;

  # FIXME: pick exactly what we require for jellyfin
  # https:/graphics.wiki/wiki/Jellyfin
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      intel-vaapi-driver
      vaapiIntel
      libvdpau-va-gl
      intel-compute-runtime-legacy1 # OpenCL filter support (hardware tonemapping and subtitle burn-in), Gen 8,9,11
      vpl-gpu-rt # QSV on 11th gen or newer
      intel-media-sdk # QSV up to 11th gen
      ocl-icd
    ];
  };

  services.logrotate.enable = true;

  #services.zrepl.enable = true;

  zramSwap.enable = true;
  services.uptimed.enable = true;

  services.qbittorrent = {
    enable = true;
    webui-port = 10114;
  };

  systemd.services.qbittorrent = {
    requires = [ "pia-wg.service" ];
    after = [ "pia-wg.service" ];

    serviceConfig = {
      NetworkNamespacePath = "/run/netns/pia";

      BindReadOnlyPaths = [ "/etc/netns/pia/resolv.conf:/etc/resolv.conf" ];
      BindPaths = [ "/tank/DATA/cbz" "/tank/DATA/bt-downloads" ];
    };
  };

  systemd.sockets."qbittorrent-rpc-proxy" = {
    socketConfig = {
      ListenStream = "127.0.0.1:${toString config.services.qbittorrent.webui-port}";
      Accept = "no";
    };
    wantedBy = [ "sockets.target" ];
  };

  systemd.services."qbittorrent-rpc-proxy" = {
    after = [ "qbittorrent-rpc-proxy.socket" "pia-wg.service" ];
    requires = [ "qbittorrent-rpc-proxy.socket" "pia-wg.service" ];
    serviceConfig = {
      DynamicUser = true;

      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --exit-idle-time=5m 127.0.0.1:${toString config.services.qbittorrent.webui-port}";
      NetworkNamespacePath = "/run/netns/pia";
    };
  };

  # FIXME: this writes configuration into `/var/lib/transmission`, which we
  # normally wipe and bind mount to preserve. This causes the same issues komga
  # has. Examine relocating the config elsewhere or applying it in some
  # alternate fashion
  services.transmission = {
    enable = true;
    package = pkgs.transmission_4;
    settings = {
      download-dir = "/tank/DATA/bt-downloads/complete";
      incomplete-dir = "/tank/DATA/bt-downloads/incomplete";
      rpc-port = transmissionPort;
      rpc-authentication-required = false;
      rpc-host-whitelist = "transmission.arnold.einic.org";
      rpc-bind-address = "127.0.0.1";
      port-forwarding-enabled = false;
    };
  };

  systemd.services.transmission = {
    requires = [ "pia-wg.service" ];
    after = [ "pia-wg.service" ];

    serviceConfig = {
      NetworkNamespacePath = "/run/netns/pia";
      # Bind mount resolv.conf into the network namespace
      # https://github.com/chrisbouchard/namespaced-wireguard-vpn/issues/9
      BindReadOnlyPaths = [ "/etc/netns/pia/resolv.conf:/etc/resolv.conf" ];
      BindPaths = [ "/tank/DATA/cbz" "/tank/DATA/bt-downloads" ];
    };
  };

  systemd.sockets."transmission-rpc-proxy" = {
    socketConfig = {
      ListenStream = "127.0.0.1:${toString transmissionPort}";
      Accept = "no";
    };
    wantedBy = [ "sockets.target" ];
  };

  systemd.services."transmission-rpc-proxy" = {
    after = [ "transmission-rpc-proxy.socket" "pia-wg.service" ];
    requires = [ "transmission-rpc-proxy.socket" "pia-wg.service" ];
    serviceConfig = {
      DynamicUser = true;

      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --exit-idle-time=5m 127.0.0.1:${toString transmissionPort}";
      NetworkNamespacePath = "/run/netns/pia";

      #ProtectSystem = "strict";
      #ProtectHome = true;
      #PrivateDevices = true;
      #PrivateTmp = true;
      #PrivateIPC = true;
      #PrivatePIDs = true;
      #PrivateUsers = true;
      #ProtectHostname = true;
      #ProtectClock = true;
      #ProtectKernelTunables = true;
      #ProtectKernelModules = true;
      #ProtectKernelLogs = true;
      #ProtectControlGroups = true;
      #RestrictAddressFamilies="AF_INET AF_INET6";
      #LockPersonality = true;
      #MemoryDenyWriteExecute = true;
      #RestrictRealtime = true;
      #RestrictSUIDSGID = true;
      #RemoveIPC = true;
      #PrivateMounts = true;
    };
  };


  # https://www.cloudnull.io/2019/04/running-services-in-network-name-spaces-with-systemd/
  # https://www.ismailzai.com/blog/creating-wireguard-jails-with-linux-network-namespaces
  # https://github.com/dadevel/wg-netns
  # https://github.com/existentialtype/deluge-namespaced-wireguard
  systemd.services.pia-netns = {
    description = "Create a network namespace for PIA VPN";
    wantedBy = [ "multi-user.target" ];

    path = [ pkgs.iproute2 ];

    script = ''
      #!/bin/sh
      set -e

      netns="pia"
      trap "ip netns del $netns" EXIT
      ip netns add "$netns"
      ip -n "$netns" link set lo up

      ip link add wg-"$netns" type wireguard
      ip link set wg-"$netns" netns "$netns"

      # we fill this in with `pia-wg.service`
      mkdir -p /etc/netns/"$netns"
      touch /etc/netns/"$netns"/resolv.conf

      trap - EXIT
    '';

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStop = "${pkgs.iproute2}/bin/ip netns del pia";
    };
  };

  # TODO: instead of having a ping loop internally, consider using a timer to send pings & restart the service if needed.
  systemd.services.pia-wg = {
    description = "Connect to PIA VPN";
    requires = [ "pia-netns.service" ];
    after = [ "pia-netns.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      EnvironmentFile = "/persist/etc/default/pia-wg";
      StateDirectory = "pia-wg";
      ExecStart = "${pia-wg-util}/bin/pia-wg-util ''$STATE_DIRECTORY pia ca";
      # TODO: add ExecStop to disconnect/reset the wireguard interface
    };
  };

  services.locate = {
    enable = true;
  };

  services.smartd = {
    enable = true;
    defaults.monitored = "-a -o on -s (S/../.././02|L/../../7/04)";
  };

  services.sabnzbd = {
    # TODO: generate/track config file here instead of using the default
    enable = true;
    configFile = "/persist/etc/sabnzbd/sabnzbd.ini";
  };

  services.prowlarr = {
    # TODO: set port here
    enable = true;
  };

  services.readarr = {
    # TODO: set port here
    enable = true;
  };

  services.sonarr = {
    enable = true;
  };

  services.radarr = {
    enable = true;
  };

  # FIXME: use dynamic user.
  users.users.recyclarr = {
    description = "Recyclarr";
    isSystemUser = true;
    group = "recyclarr";
  };
  users.groups.recyclarr = { };

  # FIXME: use dynamic user.
  systemd.services.recyclarr = {
    serviceConfig = {
      #User = "${config.users.users.recyclarr.name}";
      #Group = "${config.users.users.recyclarr.group}";
      Type = lib.mkForce "oneshot";
      Restart = lib.mkForce "on-failure";
    };

    # NOTE: oci-containers doesn't let us pass arbitrary shell substituions so we
    # can't get runtime values for the user/group. So we poke the script
    # manually.
    # This means that we're ignoring the upstream generation of the script, but
    # it works pretty well.
    # NOTE: using `--uidmap` breaks podman, so we use `--user` instead.
    script = lib.mkForce ''
      exec podman  \
        run \
        --rm \
        --name=recyclarr \
        --log-driver=journald \
        --cidfile=/run/podman-recyclarr.ctr-id \
        --cgroups=no-conmon \
        --sdnotify=conmon \
        -d \
        --replace \
        -e TZ=America/New_York \
        -v /persist/var/lib/private/recyclarr:/config \
        -v ${config.sops.templates."recyclarr-secrets.yml".path}:/config/secrets.yml:ro \
        -v "${./recyclarr/recyclarr.yml}:/config/recyclarr.yml:ro" \
        -v "${./recyclarr/settings.yml}:/config/settings.yml:ro" \
        -l io.containers.autoupdate=registry \
        --pull missing \
        '--security-opt=no-new-privileges' \
        --user $(id -u recyclarr):$(id -g recyclarr) \
        ghcr.io/recyclarr/recyclarr \
        sync \
        --app-data \
        /config
    '';
  };

  systemd.timers.recyclarr = {
    timerConfig = {
      Persistent = true;
      OnCalendar = "daily";
      AccuracySec = "1h";
      RandomizedDelaySec = "1h";
    };
  };

  virtualisation.oci-containers.containers.recyclarr = {
    autoStart = false;
    image = "ghcr.io/recyclarr/recyclarr";
    serviceName = "recyclarr";
    /*
      extraOptions = [
        "--security-opt=no-new-privileges"
        "--uidmap=1000:$(id -u ${config.users.users.recyclarr.name})"
        "--gidmap=1000:$(id -g ${config.users.users.recyclarr.name})"
      ];
      cmd = [ "sync" "--app-data" "/config" ];
      environment = {
        TZ = "America/New_York";
      };
      volumes = [
        "/persist/var/lib/private/recyclarr:/config"
        "/run/secrets/recyclarr-secrets.yml:/config/secrets.yml:ro"
        "${./recyclarr/recyclarr.yml}:/config/recyclarr.yml:ro"
        "${./recyclarr/settings.yml}:/config/settings.yml:ro"
      ];
      labels = {
        "io.containers.autoupdate" = "registry";
      };
      */
  };

  sops.secrets."radarr-api-key" = {
    sopsFile = ./secrets.yml;
    key = "radarr-api-key";
  };

  sops.secrets."sonarr-api-key" = {
    sopsFile = ./secrets.yml;
    key = "sonarr-api-key";
  };

  sops.secrets."readarr-api-key" = {
    sopsFile = ./secrets.yml;
    key = "readarr-api-key";
  };

  sops.secrets."prowlarr-api-key" = {
    sopsFile = ./secrets.yml;
    key = "prowlarr-api-key";
  };

  sops.templates."recyclarr-secrets.yml" = {
    content = ''
      sonarr_api_key: ${config.sops.placeholder.sonarr-api-key}
      radarr_api_key: ${config.sops.placeholder.radarr-api-key}
    '';

    owner = "${config.users.users.recyclarr.name}";
  };

  systemd.services.radarr = {
    serviceConfig = {
      # TODO: poke the database to configure a user, or poke the API using the API key.
      ExecStartPre = ''
        ${pkgs.coreutils}/bin/cp -f ${config.sops.templates."radarr-config.xml".path} /var/lib/radarr/.config/Radarr/config.xml
      '';
    };
  };

  sops.templates."radarr-config.xml" = {
    restartUnits = [ "radarr.service" ];
    owner = "${config.users.users.radarr.name}";
    content = ''
      <Config>
        <BindAddress>127.0.0.1</BindAddress>
        <Port>${toString radarr-port}</Port>
        <SslPort>9898</SslPort>
        <EnableSsl>False</EnableSsl>
        <LaunchBrowser>True</LaunchBrowser>
        <ApiKey>${config.sops.placeholder.radarr-api-key}</ApiKey>
        <AuthenticationMethod>Forms</AuthenticationMethod>
        <AuthenticationRequired>Enabled</AuthenticationRequired>
        <Branch>master</Branch>
        <LogLevel>debug</LogLevel>
        <SslCertPath></SslCertPath>
        <SslCertPassword></SslCertPassword>
        <UrlBase></UrlBase>
        <InstanceName>Radarr</InstanceName>
      </Config>
    '';
  };

  systemd.services.sonarr = {
    serviceConfig = {
      # TODO: poke the database to configure a user, or poke the API using the API key.
      ExecStartPre = ''
        ${pkgs.coreutils}/bin/cp -f ${config.sops.templates."sonarr-config.xml".path} /var/lib/sonarr/.config/NzbDrone/config.xml
      '';
    };
  };

  sops.templates."sonarr-config.xml" = {
    restartUnits = [ "sonarr.service" ];
    owner = "${config.users.users.sonarr.name}";
    content = ''
      <Config>
        <BindAddress>127.0.0.1</BindAddress>
        <Port>${toString sonarr-port}</Port>
        <SslPort>9898</SslPort>
        <EnableSsl>False</EnableSsl>
        <LaunchBrowser>True</LaunchBrowser>
        <ApiKey>${config.sops.placeholder.sonarr-api-key}</ApiKey>
        <AuthenticationMethod>Forms</AuthenticationMethod>
        <AuthenticationRequired>Enabled</AuthenticationRequired>
        <Branch>main</Branch>
        <LogLevel>debug</LogLevel>
        <SslCertPath></SslCertPath>
        <SslCertPassword></SslCertPassword>
        <UrlBase></UrlBase>
        <InstanceName>Sonarr</InstanceName>
      </Config>
    '';
  };

  systemd.services.readarr = {
    serviceConfig = {
      ExecStartPre = ''
        ${pkgs.coreutils}/bin/cp -f ${config.sops.templates."readarr-config.xml".path} /var/lib/readarr/config.xml
      '';
    };
  };

  sops.templates."readarr-config.xml" = {
    restartUnits = [ "readarr.service" ];
    owner = "${config.users.users.readarr.name}";
    content = ''
      <Config>
        <BindAddress>127.0.0.1</BindAddress>
        <Port>${toString readarr-port}</Port>
        <SslPort>6868</SslPort>
        <EnableSsl>False</EnableSsl>
        <LaunchBrowser>True</LaunchBrowser>
        <ApiKey>${config.sops.placeholder.readarr-api-key}</ApiKey>
        <AuthenticationMethod>None</AuthenticationMethod>
        <AuthenticationRequired>Enabled</AuthenticationRequired>
        <Branch>develop</Branch>
        <LogLevel>debug</LogLevel>
        <SslCertPath></SslCertPath>
        <SslCertPassword></SslCertPassword>
        <UrlBase></UrlBase>
        <InstanceName>Readarr</InstanceName>
      </Config>
    '';
  };

  systemd.services.prowlarr = {
    serviceConfig = {
      ExecStartPre = ''
        ${pkgs.coreutils}/bin/cp -f ${config.sops.templates."prowlarr-config.xml".path} /var/lib/prowlarr/config.xml
      '';
    };
  };

  sops.templates."prowlarr-config.xml" = {
    restartUnits = [ "prowlarr.service" ];
    owner = "${config.users.users.prowlarr.name}";
    content = ''
      <Config>
        <BindAddress>127.0.0.1</BindAddress>
        <Port>${toString prowlarr-port}</Port>
        <SslPort>6969</SslPort>
        <EnableSsl>False</EnableSsl>
        <LaunchBrowser>True</LaunchBrowser>
        <ApiKey>${config.sops.placeholder.prowlarr-api-key}</ApiKey>
        <AuthenticationMethod>Forms</AuthenticationMethod>
        <AuthenticationRequired>Enabled</AuthenticationRequired>
        <Branch>master</Branch>
        <LogLevel>debug</LogLevel>
        <SslCertPath></SslCertPath>
        <SslCertPassword></SslCertPassword>
        <UrlBase></UrlBase>
        <InstanceName>Prowlarr</InstanceName>
      </Config>
    '';
  };

  system.stateVersion = "24.11";
}
