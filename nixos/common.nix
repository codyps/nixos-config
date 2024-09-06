{ pkgs, self, ... }:
{
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      trusted-users = [ "nix-ssh" "@wheel" ];

      substituters = [ "https://ward.little-moth.ts.net/harmonia" ];
      trusted-public-keys = [
        "ward.einic.org-1:MVzXNXGliDxO/juzN9Vo+NHVrnRA6F/sHC4k1mb/iYI="
      ];
    };
    optimise.automatic = true;
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
    #buildMachines = [
    #];
    #distributedBuilds = true;
    sshServe = {
      enable = true;
      write = true;
      protocol = "ssh-ng";
    };
  };

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
    randomizedDelaySec = "45min";
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
