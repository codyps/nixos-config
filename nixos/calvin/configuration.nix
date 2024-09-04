{ config, pkgs, lib, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
    ];


  nix = {
    package = pkgs.nixFlakes;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
    nixPath =
      [
        "nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos"
        "nixos-config=/persist/etc/nixos/configuration.nix"
        "/nix/var/nix/profiles/per-user/root/channels"
      ];
  };

  boot.initrd.postDeviceCommands = lib.mkAfter ''
    zfs rollback -r calvin/local/root@blank
  '';

  boot.initrd.luks.devices = {
    calvin-crypt = {
      device = "/dev/disk/by-uuid/cac206a2-6cf7-433d-99e5-51d0105d4a38";
      allowDiscards = true;
      preLVM = true;
    };
  };

  fileSystems."/var/lib/tailscale" = {
    device = "/persist/var/lib/tailscale";
    options = [ "bind" ];
    noCheck = true;
  };

  hardware.cpu.intel.updateMicrocode = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  time.timeZone = "America/New_York";

  networking = {
    hostName = "calvin";
    useDHCP = false;
    dhcpcd.enable = false;
    useNetworkd = true;
  };

  systemd.network = {
    enable = true;
    wait-online.anyInterface = true;
    networks = {
      "40-eno1" = {
        matchConfig.Name = "eno1";
        networkConfig = {
          DHCP = "ipv4";
          DNSSEC = "no";
        };
      };
    };
  };

  programs.zsh.enable = true;

  environment.systemPackages = with pkgs;
    [
      neovim
      tailscale
      atuin
    ];

  networking.hostId = "607213bf";

  programs.sway = {
    enable = true;
    wrapperFeatures.gtk = true;
    extraPackages = with pkgs; [
      swaylock
      swayidle
      wl-clipboard
      mako
      alacritty
      wofi
    ];
  };

  # Configure keymap in X11
  # services.xserver.layout = "us";
  # services.xserver.xkbOptions = "eurosign:e";

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound.
  # sound.enable = true;
  # hardware.pulseaudio.enable = true;

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  services.tailscale.enable = true;

  services.zfs = {
    autoScrub.enable = true;
  };
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = true;
    };
    hostKeys =
      [
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

  environment.shells = with pkgs; [ zsh ];

  users = {
    defaultUserShell = pkgs.zsh;
    mutableUsers = false;
    users = {
      root = { };

      y = {
        createHome = true;
        extraGroups = [ "wheel" ];
        group = "users";
        uid = 1000;
        home = "/home/y";
        isNormalUser = true;
      };
      nix = {
        createHome = true;
        home = "/home/nix";
        group = "users-remote";
        uid = 1100;
        useDefaultShell = true;
        isNormalUser = true;
      };
    };
  };

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "21.05"; # Did you read the comment?
}
