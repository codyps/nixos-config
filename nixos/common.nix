{ pkgs, self, config, ... }:
let hostname = config.networking.hostName;
in
{

  imports = [
    ../modules/build-machines.nix
  ];

  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      trusted-users = [ "nix-ssh" "@wheel" ];

      substituters = if hostname != "ward" then [ "https://ward.little-moth.ts.net/harmonia" ] else [ ];
      trusted-public-keys =
        if hostname != "ward" then [
          "ward.einic.org-1:MVzXNXGliDxO/juzN9Vo+NHVrnRA6F/sHC4k1mb/iYI="
        ] else [ ];
    };
    optimise.automatic = true;
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
    #distributedBuilds = true;
    sshServe = {
      enable = true;
      write = true;
      protocol = "ssh-ng";
    };
  };

  p.nix.buildMachines.ward = hostname != "ward";

  system.autoUpgrade = {
    enable = true;
    flake = self.outPath;
    flags = [
      "--update-input"
      "nixpkgs"
      "--no-write-lock-file"
      "-L" # print build logs
    ];
    dates = "02:00";
    randomizedDelaySec = "90min";
  };

  i18n.defaultLocale = "en_US.UTF-8";

  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;

    # TODO: pinentry? need to know which one is appropriate for system.
  };
  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;

  services.tailscale.enable = true;

  system.extraSystemBuilderCmds = "ln -s ${./.} $out/full-config";
}
