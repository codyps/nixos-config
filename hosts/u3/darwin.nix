{ config, ... }: {
  homebrew = {
    enable = true;

    taps = [ ];
    #brews = [ "meshtastic" ];
    casks = [ ];
  };

  nix.linux-builder.enable = true;

  # Keep build-time store optimisation disabled: creating hard links is
  # particularly expensive on APFS. Do it once a week after garbage
  # collection instead.
  nix.settings.auto-optimise-store = false;

  nix.gc = {
    automatic = true;
    interval = [{ Weekday = 7; Hour = 3; Minute = 15; }];
    options = "--delete-older-than 30d";
  };

  nix.optimise = {
    automatic = true;
    interval = [{ Weekday = 7; Hour = 4; Minute = 15; }];
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
