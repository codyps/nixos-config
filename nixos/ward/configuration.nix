{ config, lib, pkgs, ... }:

let
  ssh-auth = (import ../ssh-auth.nix);
  authorizedKeys = ssh-auth.authorizedKeys;
in
{
  imports =
    [
      ./hardware-configuration.nix
    ];

  boot.kernelParams = [ "ip=dhcp" ];
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  systemd.watchdog.runtimeTime = "30s";

  # hashedPasswordFile reads from this
  fileSystems."/persist".neededForBoot = true;

  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/bluetooth"
      "/var/lib/nixos"
      "/var/lib/upower"
      "/var/lib/tailscale"
      "/var/lib/systemd/coredump"
      "/etc/NetworkManager/system-connections"
      { directory = "/var/lib/colord"; user = "colord"; group = "colord"; mode = "u=rwx,g=rx,o="; }
    ];
    files = [
      "/etc/machine-id"
    ];
  };

  boot.initrd = {
    systemd.enable = true;

    systemd.services.rollback = {
      description = "Rollback ZFS datasets to a pristine state";
      wantedBy = [
        "initrd.target"
      ];
      after = [
        # TODO: use systemd generated targets instead
        "zfs-import-ward.service"
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
        zfs rollback -r ward/temp/root@blank && echo "rollback complete"
      '';
    };

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

  services.hydra = {
    enable = true;
    hydraURL = "https://ward.little-moth.ts.net/hydra";
    notificationSender = "hydra@localhost"; # e-mail of hydra service
    # a standalone hydra will require you to unset the buildMachinesFiles list to avoid using a nonexistant /etc/nix/machines
    buildMachinesFiles = [ ];
    # you will probably also want, otherwise *everything* will be built from scratch
    useSubstitutes = true;
    listenHost = "localhost";
  };

  services.harmonia = {
    enable = true;
    signKeyPaths = [
      "/persist/etc/nix-binary-cache/binary-cache.secret"
    ];
    settings.bind = "[::1]:8916";
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

  services.caddy = {
    enable = true;
    virtualHosts."ward.little-moth.ts.net" = {
      listenAddresses = [ "100.115.212.42" ];
      extraConfig = ''
        root /srv

        handle_path /harmonia/* {
          reverse_proxy http://localhost:8916 {
            #header_up Host {host}
            #header_up X-Forwarded-For {remote}
            #header_up Upgrade {upstream_http_upgrade}
            #header_up Connection {upstream_http_connection}
          }
        }

        handle_path /hydra/* {
          reverse_proxy http://localhost:3000 {
            header_up Host {upstream_hostport}
            header_up X-Request-Base /hydra
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

  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  services.tailscale.permitCertUid = "caddy";
  services.tailscaleAuth = {
    enable = true;
    user = "caddy";
    group = "caddy";
  };

  networking.hostName = "ward";
  networking.hostId = "5c794628";

  time.timeZone = "America/New_York";

  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  #   useXkbConfig = true; # use xkb.options in tty.
  # };

  # Enable the X11 windowing system.
  services.xserver.enable = true;


  # Enable the GNOME Desktop Environment.
  services.xserver.displayManager.gdm.enable = true;
  services.xserver.desktopManager.gnome.enable = true;


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

  #system.copySystemConfiguration = true;

  system.stateVersion = "23.11";
}

