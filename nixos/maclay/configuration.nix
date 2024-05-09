{ config, lib, pkgs, ... }:

{
  imports =
    [
      # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  nix = {
    package = pkgs.nixFlakes;
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      trusted-users = [ "nix-ssh" "@wheel" ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
    #buildMachines = [
    #  {
    #    hostname = "RIV-066789M";
    #    system = "aarch64-darwin";
    #    maxJobs = 8;
    #    speedFactor = 1;
    #  }
    #];
    #distributedBuilds = true;
    sshServe = {
      enable = true;
      write = true;
      protocol = "ssh-ng";
      keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINnPgVJMpHAMdQ8M87JtufVrZ833hgROViMEexg+sBp6 root@RIV-066789M"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMTg+MBb/ao0R1kBP5mHosOPADfy/4x2yKuQPx2c72Ie root@RIV-066789M"
      ];
    };
  };

  environment.shells = with pkgs; [ zsh ];

  services.qemuGuest.enable = true;

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "maclay";
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";
  programs.zsh.enable = true;

  # Select internationalisation properties.
  # i18n.defaultLocale = "en_US.UTF-8";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  #   useXkbConfig = true; # use xkb.options in tty.
  # };

  # Enable the X11 windowing system.
  services.xserver = {
    enable = true;
    libinput.enable = true;
    desktopManager.xterm.enable = false;

    displayManager = {
      defaultSession = "none+i3";
      sessionCommands = ''
        ${pkgs.xorg.xrandr}/bin/xrandr -s 1920x1080
      '';
    };

    windowManager.i3 = {
      enable = true;
      extraPackages = with pkgs; [
        dmenu
        i3status
      ];
    };
  };

  # Configure keymap in X11
  services.xserver.xkb.layout = "us";
  services.xserver.xkb.options = "caps:escape";

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound.
  # sound.enable = true;
  # hardware.pulseaudio.enable = true;

  users.users.cody = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    packages = with pkgs; [
      firefox
      kitty
    ];
    shell = pkgs.zsh;
  };

  environment.systemPackages = with pkgs; [
    neovim
    wget
    pinentry-curses
    xclip
  ];

  programs.mtr.enable = true;
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;

    # Added to get prompted on ssh?
    pinentryPackage = lib.mkForce pkgs.pinentry-gtk2;
  };

  services.openssh.enable = true;

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  system.extraSystemBuilderCmds = "ln -s ${../.} $out/full-config";

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "23.11"; # Did you read the comment?

}

