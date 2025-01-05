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
        # ssh-keygen -t ed25519 -N "" -f /etc/secrets/initrd/ssh_host_ed25519_key
        hostKeys = [ "/persist/etc/secret/initrd/ssh_host_ed25519_key" ];
      };
    };

    availableKernelModules = [ "zfs" ];

    # TODO: match required modules
    kernelModules = [ "usb_storage" "igc" "tpm_crb" "zfs" "uas" "nvme" "bonding" ];

    systemd.services."zfs-import-mainrust".requiredBy = [ "initrd.mount" ];
    systemd.services."zfs-import-mainrust".before = [ "initrd.mount" ];

    systemd.services."zfs-load-key-mainrust-enc" = {
      description = "Load ZFS encryption key for mainrust/enc";
      requiredBy = [ "sysroot.mount" "create-needed-for-boot-dirs.service" ];
      before = [ "sysroot.mount" "shutdown.target" "create-needed-for-boot-dirs.service" ];
      after = [ "zfs-import-mainrust.service" "systemd-ask-password-console.service" ];
      requires = [ "zfs-import-mainrust.service" ];
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
      "/etc/fstab".text = ''
        mainrust/initrd /initrd zfs defaults 0 0
        /initrd/var/lib/tailscale /var/lib/tailscale auto x-systemd.requires-mounts-for=/initrd,bind,X-fstrim.notrim,x-gvfs-hide 0 0
      '';
    };

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

  system.stateVersion = "24.11";
}
