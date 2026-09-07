{ config, lib, pkgs, ... }:
let
  primary-user = config.system.primaryUser;
  primary-home = config.users.users.${primary-user}.home;
  docker-builder-state = "${primary-home}/.local/state/nix-docker-builder";
  docker-builder-proxy = pkgs.writeShellScript "docker-builder-proxy" ''
    exec ${pkgs.python3}/bin/python3 ${../../scripts/docker-linux-builder/proxy.py} \
      --docker ${lib.escapeShellArg "${primary-home}/.orbstack/bin/docker"}
  '';
  nix-maintenance = pkgs.writeShellApplication {
    name = "nix-maintenance";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
    ];
    text = builtins.readFile ../../scripts/nix-maintenance.sh;
  };
in
{
  homebrew = {
    enable = true;

    taps = [ ];
    #brews = [ "meshtastic" ];
    casks = [ ];
  };

  nix.linux-builder.enable = true;
  # Keep the VM and its cached store available for manual use. Setting enable
  # to false deletes its working directory in nix-darwin's activation script.
  launchd.daemons.linux-builder.serviceConfig = {
    RunAtLoad = lib.mkForce false;
    KeepAlive = lib.mkForce false;
  };

  # The small host proxy owns container lifecycle under the primary user's OrbStack.
  launchd.daemons.docker-linux-builder = {
    command = "${docker-builder-proxy}";
    environment.HOME = primary-home;
    serviceConfig = {
      UserName = primary-user;
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      StandardOutPath = "${primary-home}/Library/Logs/docker-linux-builder.log";
      StandardErrorPath = "${primary-home}/Library/Logs/docker-linux-builder.log";
    };
  };

  environment.etc."ssh/ssh_config.d/101-docker-linux-builder.conf".text = ''
    Host docker-linux-builder
      HostName 127.0.0.1
      Port 31023
      User root
      IdentityFile ${docker-builder-state}/id_ed25519
      IdentitiesOnly yes
      HostKeyAlias docker-linux-builder
      UserKnownHostsFile ${docker-builder-state}/known_hosts
      StrictHostKeyChecking yes
      ConnectTimeout 60
      ServerAliveInterval 30
      ServerAliveCountMax 3
  '';

  # Keep build-time store optimisation disabled: creating hard links is
  # particularly expensive on APFS. The maintenance job does it after GC.
  nix.settings.auto-optimise-store = false;

  # A single ordered job ensures optimisation always follows age-based GC.
  # Its wrapper waits on battery and suspends an active phase until AC returns.
  nix.gc.automatic = false;
  nix.optimise.automatic = false;
  launchd.daemons.nix-maintenance = {
    command = "${nix-maintenance}/bin/nix-maintenance";
    serviceConfig = {
      RunAtLoad = false;
      StartCalendarInterval = [{ Weekday = 7; Hour = 3; Minute = 15; }];
      ProcessType = "Background";
      LowPriorityIO = true;
      # Keep the store work in the supervised process group so STOP/CONT
      # pauses the filesystem activity rather than only a nix-daemon client.
      EnvironmentVariables.NIX_REMOTE = "local";
    };
  };

  # Replace the manual QEMU VM with the container; retain the remote fallback.
  nix.buildMachines = lib.mkForce [ {
    hostName = "docker-linux-builder";
    sshUser = "root";
    protocol = "ssh-ng";
    sshKey = "${docker-builder-state}/id_ed25519";
    systems = [ "x86_64-linux" ];
    maxJobs = 4;
    speedFactor = 20;
    supportedFeatures = [ "benchmark" "big-parallel" ];
  } {
    hostName = "mifflin";
    sshUser = "nix-ssh";
    systems = [ "x86_64-linux" ];
    maxJobs = 4;
    speedFactor = 10;
    supportedFeatures = [ "kvm" "benchmark" "big-parallel" ];
    publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUVEdk1iRis5WVBLc2FhZC9saHd4Vlp5a1VTUVQxRmJ5ODJ2T3hOc2xCNUggcm9vdEBuaXhvcwo=";
    protocol = "ssh-ng";
    sshKey = "${config.sops.secrets."mifflin-ssh-key".path}";
  }];

  sops.age.sshKeyPaths = [
    "/etc/ssh/ssh_host_ed25519_key"
  ];

  sops.secrets."mifflin-ssh-key" = {
    sopsFile = ./secrets.yml;
    key = "mifflin-ssh-key";
  };
}
