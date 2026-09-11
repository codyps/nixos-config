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
      ./secrets.nix
      ./media.nix
      (modulesPath + "/profiles/qemu-guest.nix")
    ];

  services.logrotate.checkConfig = false;

  system.autoUpgrade.enable = lib.mkForce false;
  nix.optimise.automatic = lib.mkForce false;
  nix.gc.automatic = lib.mkForce false;

  # mkDefault so it is overridden when building the vm
  boot.zfs.devNodes = lib.mkDefault "/dev/robin-vg";
  boot.zfs.forceImportRoot = false;

  boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod" ];
  boot.initrd.kernelModules = [ "virtio_net" ];
  boot.kernelModules = [ "kvm-intel" ];

  boot.initrd.network = {
    enable = true;
    ssh = {
      enable = true;
      port = 2222;
      inherit authorizedKeys;
      # Separate from the SOPS identity: this key is copied into unencrypted /boot.
      hostKeys = [ "/persist/ssh/initrd_ssh_host_ed25519_key" ];
    };
  };
  boot.initrd.systemd.network.networks."10-en" = {
    matchConfig.Name = "en*";
    networkConfig.DHCP = "ipv4";
  };
  boot.initrd.systemd.users.root.shell = "/bin/systemd-tty-ask-password-agent";

  # Do not start the ZFS import timeout while waiting for manual LUKS unlock.
  boot.initrd.systemd.services.zfs-import-robin = {
    requires = [ "dev-robin\\x2dvg-zfs.device" ];
    after = [ "dev-robin\\x2dvg-zfs.device" ];
  };

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

  systemd.services.caddy =
    let
      mounts = [ "tank-libation.mount" "tank-syncthing.mount" ];
    in
    {
      serviceConfig = {
        EnvironmentFile = config.sops.templates."caddy-env".path or [ ];
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
          root /tank/libation/data/
          file_server browse
        }

        @audiobookshelf host audiobookshelf.einic.org
        handle @audiobookshelf {
          redir / /audiobookshelf/ 302
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
    hashedPasswordFile = config.sops.secrets."root-password-hash".path or null;
  };
  users.users.cody = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPasswordFile = config.sops.secrets."cody-password-hash".path or null;
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
  networking.firewall.allowedTCPPorts = [ 22 443 80 22000 ];
  networking.firewall.allowedUDPPorts = [ 443 22000 41641 ];
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  # enable tailscale exit
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;

  services.tailscale.permitCertUid = "caddy";

  zramSwap.enable = true;

  system.stateVersion = "26.10";
}
