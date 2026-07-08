{ config, ... }: {
  homebrew = {
    enable = true;

    taps = [ ];
    #brews = [ "meshtastic" ];
    casks = [ ];
  };

  nix.linux-builder.enable = true;

  nix.buildMachines = [{
    hostName = "mifflin";
    systems = [ "x86_64-linux" "aarch64-linux" ];
    maxJobs = 4;
    speedFactor = 10;
    supportedFeatures = [ "kvm" "benchmark" "big-parallel" ];
    publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUVEdk1iRis5WVBLc2FhZC9saHd4Vlp5a1VTUVQxRmJ5ODJ2T3hOc2xCNUggcm9vdEBuaXhvcwo=";
    protocol = "ssh-ng";
    sshKey = "${config.sops.secrets."mifflin-ssh-key".path}";
  }];

  programs.codex = {
    enable = true;
    settings = {
      sandbox_workspace_write = {
        network_access = true;
        sandbox_mode = "danger-full-access";
      };
    };
  };

  sops.age.sshKeyPaths = [
    "/etc/ssh/ssh_host_ed25519_key"
  ];

  sops.secrets."mifflin-ssh-key" = {
    sopsFile = ./secrets.yml;
    key = "mifflin-ssh-key";
  };
}

