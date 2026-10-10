{ config, lib, pkgs, ... }:
let
  inherit (import ../../nixos/ssh-auth.nix) authorizedKeys;
  volumeIdentity = import ./volume-identity.nix;
in
{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ./reset-root.nix
    ./wifi.nix
    ./ai-container.nix
    ./secure-boot.nix
    ../../nixos-modules/secure-unlock
    ../warbler/account-passwords.nix
  ];
  networking.hostName = "crow";
  time.timeZone = "America/New_York";
  system.stateVersion = "26.05";
  boot.secureUnlock = {
    enable = true;
    stateDirectory = "/persist";
    rootVolumeKeyId = volumeIdentity;
    tpmUnlock.enable = true;
    remoteUnlock = {
      enable = true;
      inherit authorizedKeys;
      tailscale.enable = true;
      wifi = { enable = true; backend = "iwd"; interface = "wlp6s0"; iwdProfileName = "billy.psk"; };
    };
  };
  boot.loader.efi.canTouchEfiVariables = true;
  boot.lanzaboote = {
    pkiBundle = "/persist/var/lib/sbctl";
    measuredBoot = {
      pcrlockDirectory = "/persist/var/lib/pcrlock.d";
      pcrlockPolicy = "/persist/var/lib/systemd/pcrlock.json";
    };
  };
  fileSystems."/persist".neededForBoot = true;
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [ "/var/lib" "/var/log" "/var/db" "/root" ];
    files = [ "/etc/machine-id" ];
  };
  # Disk swap is an LV inside cryptroot. Hibernation is intentionally disabled.
  boot.kernelParams = [ "nohibernate" ];
  users.users.root.openssh.authorizedKeys.keys = authorizedKeys;
  users.users.cody = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = authorizedKeys;
  };
  security.sudo.wheelNeedsPassword = false;
  services.openssh = {
    enable = true;
    settings = { PermitRootLogin = "prohibit-password"; PasswordAuthentication = false; KbdInteractiveAuthentication = false; };
    hostKeys = [{ path = "/persist/ssh/ssh_host_ed25519_key"; type = "ed25519"; }];
  };
  networking.firewall.enable = true;
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "server";
    extraSetFlags = [ "--advertise-exit-node" ];
  };
  environment.systemPackages = with pkgs; [ sbctl cryptsetup lvm2 tpm2-tools neovim htop tmux ghostty.terminfo ];
  system.autoUpgrade.enable = lib.mkForce false;
  p.nix.buildMachines.ward.enable = lib.mkForce false;
}
