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
    securityType = "user";
    openFirewall = true;
    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "arnold";
        "netbios name" = "arnold";
        "security" = "user";
        #"use sendfile" = "yes";
        #"max protocol" = "smb2";
        # note: localhost is the ipv6 localhost ::1
        "hosts allow" = "10. 100. 192.168.0. 127.0.0.1 localhost";
        "hosts deny" = "0.0.0.0/0";
        "guest account" = "nobody";
        "map to guest" = "bad user";

        "server min protocol" = "SMB3_11";
        "server signing" = "mandatory";
        "server smb encrypt" = "required";
        "restrict anonymous" = "2";

        "fruit:metadata" = "stream";
        "fruit:resource" = "stream";
        # requires catia
        "fruit:encoding" = "native";

        "fruit:veto_appledouble" = "no";
        "fruit:posix_rename" = "yes";
        "fruit:zero_file_id" = "yes";

        "domain master" = "yes";
      };
      "tank" = {
        "path" = "/tank";
        "writable" = "yes";
        "valid users" = "cody";
      };
      "timemachine" = {
        "path" = "/tank/backup/timemachine4";
        "valid users" = "cody";
        "public" = "no";
        "writeable" = "yes";
        "force user" = "username";
        "fruit:aapl" = "yes";
        "fruit:time machine" = "yes";
        "vfs objects" = "catia fruit streams_xattr";
      };
    };
  };

  system.stateVersion = "24.11";
}
