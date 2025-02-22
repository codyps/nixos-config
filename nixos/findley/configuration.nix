# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

# NixOS-WSL specific options are documented on the NixOS-WSL repository:
# https://github.com/nix-community/NixOS-WSL

{ config, lib, pkgs, nixos-wsl, nixos-vscode-server, ... }:

{
  imports = [
    # include NixOS-WSL modules
    # <nixos-wsl/modules>
    nixos-wsl.nixosModules.default
    #<nixos-vscode-server>
    nixos-vscode-server.nixosModules.default
  ];

  wsl = {
    enable = true;
    defaultUser = "nixos";
    wslConf.automount.root = "/mnt";
    wslConf.interop.appendWindowsPath = false;
    wslConf.network.generateHosts = false;
    startMenuLaunchers = true;

    # Enable integration with Docker Desktop (needs to be installed)
    docker-desktop.enable = false;

    extraBin = with pkgs; [
      # Binaries for Docker Desktop wsl-distro-proxy
      { src = "${coreutils}/bin/mkdir"; }
      { src = "${coreutils}/bin/cat"; }
      { src = "${coreutils}/bin/whoami"; }
      { src = "${coreutils}/bin/ls"; }
      { src = "${busybox}/bin/addgroup"; }
      { src = "${su}/bin/groupadd"; }
      { src = "${su}/bin/usermod"; }
      { src = "${wget}/bin/wget"; }
    ];
  };

  programs.gnupg.agent = {
    # Added to get prompted on ssh?
    pinentryPackage = lib.mkForce pkgs.pinentry-gtk2;
  };

  #virtualisation.docker = {
  #  enable = true;
  #  enableOnBoot = true;
  #  autoPrune.enable = true;
  #};

  ## patch the script 
  systemd.services.docker-desktop-proxy.script = lib.mkForce ''${config.wsl.wslConf.automount.root}/wsl/docker-desktop/docker-desktop-user-distro proxy --docker-desktop-root ${config.wsl.wslConf.automount.root}/wsl/docker-desktop "C:\Program Files\Docker\Docker\resources"'';

  services.vscode-server.enable = true;
  #wsl.docker-desktop.enable = true;

  networking.hostName = "findley";

  programs.nix-ld = {
    enable = true;
    package = pkgs.nix-ld-rs;
  };

  virtualisation.docker.rootless.enable = true;
  #systemd.services.docker-desktop-proxy = {
  #  path = [ pkgs.mount ];
  #  script = lib.mkForce ''
  #    ${proxyPath} proxy /run/docker1.sock --docker-desktop-root ${dockerRoot}
  #  '';
  #};

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "23.11"; # Did you read the comment?
}
