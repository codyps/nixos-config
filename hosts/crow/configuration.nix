{ config, lib, pkgs, hardwareIdentities, ... }:
let
  inherit (import ../../nixos/ssh-auth.nix) authorizedKeys;
  volumeIdentity = import ./volume-identity.nix { inherit hardwareIdentities; };
in
{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ../../nixos-modules/dedupit.nix
    ./reset-root.nix
    ./wifi.nix
    ./ai-container.nix
    ../../nixos-modules/codex-remote-control.nix
    ../../nixos-modules/opencode.nix
    ./hindsight.nix
    ./secure-boot.nix
    ../../nixos-modules/secure-unlock
    ../../nixos-modules/ms-a2-power-led
    ../warbler/account-passwords.nix
  ];
  networking.hostName = "crow";
  services.dedupit.enable = true;
  services.dedupit.databaseStorage = "nocow";
  services.dedupit.device = "/dev/mapper/crow-root";
  systemd.network.networks."20-ethernet" = {
    matchConfig = {
      Name = "en* eth*";
      Type = "ether";
    };
    networkConfig = { DHCP = "yes"; IPv6AcceptRA = true; };
    dhcpV4Config = { ClientIdentifier = "mac"; RouteMetric = 100; };
    ipv6AcceptRAConfig.RouteMetric = 100;
    linkConfig.RequiredForOnline = false;
  };
  services.codex-remote-control.enable = true;
  sops.secrets.opencode-password = {
    sopsFile = ./secrets.yaml;
    mode = "0400";
    restartUnits = [ "opencode-server.service" ];
  };
  sops.secrets.strata-api-key = {
    sopsFile = ./secrets.yaml;
    mode = "0400";
    owner = "cody";
    restartUnits = [ "opencode-server.service" ];
  };
  # Managed settings live in /etc/opencode; OpenCode does not write to them.
  services.opencode = {
    enable = true;
    settings = {
      "$schema" = "https://opencode.ai/config.json";
      providers.strata = {
        name = "Strata (local)";
        package = "@opencode/ai/providers/openai-compatible";
        settings = {
          baseURL = "http://desktop-lgmeaa4.little-moth.ts.net:8080/v1";
          apiKey = "{file:${config.sops.secrets.strata-api-key.path}}";
        };
        models."qwen3.8-flash-next-iq3_s" = {
          name = "Qwen3.8-Flash-Next (local)";
          capabilities = {
            tools = true;
            input = [ "text" "image" ];
            output = [ "text" ];
            reasoning.supported = true;
          };
          compatibility.reasoningField = "reasoning_content";
          limit = {
            context = 131072;
            input = 114688;
            output = 16384;
          };
        };
      };
    };
    server = {
      enable = true;
      user = "cody";
      passwordFile = config.sops.secrets.opencode-password.path;
      tailscaleServe.enable = true;
    };
  };
  hardware.msA2.powerLed.enable = true;
  home-manager.users.cody.programs.git.signing = {
    format = lib.mkForce "ssh";
    key = lib.mkForce "~/.ssh/id_ed25519";
    signByDefault = lib.mkForce true;
  };
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
