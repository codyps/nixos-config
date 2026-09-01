{ config, pkgs, ... }:
let
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

  nix.buildMachines = [{
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
