{
  homebrew = {
    enable = true;

    taps = [ ];
    #brews = [ "meshtastic" ];
    casks = [ ];
  };

  nix.linux-builder.enable = true;

  nix.buildMachines = [{
    hostName = "mifflin";
    system = "x86_64-linux";
    maxJobs = 4;
    supportedFeatures = [ "kvm" "benchmark" "big-parallel" ];
    protocol = "ssh-ng";
  }];
}
