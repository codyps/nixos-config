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

      #substituters = [ "https://ward.little-moth.ts.net/nix-cache" ] ++ (if hostname != "ward" then [ "https://ward.little-moth.ts.net/harmonia" ] else [ ]);

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
    #distributedBuilds = true;
    sshServe = {
      enable = true;
      write = true;
      protocol = "ssh-ng";
    };
  };

  p.nix.buildMachines.ward.enable = hostname != "ward";
  p.nix.buildMachines.ward.sshKey = "/persist/etc/nix/keys/ward";

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

  # https://github.com/quic-go/quic-go/wiki/UDP-Buffer-Sizes
  boot.kernel.sysctl."net.core.rmem_max" = 7500000;
  boot.kernel.sysctl."net.core.wmem_max" = 7500000;

  # wait-online is busted all the time without this, especially when using tailscale
  systemd.network.wait-online.anyInterface = true;

  system.extraSystemBuilderCmds = "ln -s ${./.} $out/full-config";
}
