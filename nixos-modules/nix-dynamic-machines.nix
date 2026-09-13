{ config, lib, pkgs, ... }:
let
  cfg = config.services.nix-dynamic-machines;
  service = import ../modules/nix-dynamic-machines-service.nix {
    inherit config lib pkgs;
    directory = "/var/lib/nix-dynamic-machines";
  };
in
{
  imports = [ ../modules/nix-dynamic-machines.nix ];

  config = lib.mkIf cfg.enable {
    nix.settings.builders = service.builders;
    system.activationScripts.nix-dynamic-machines.text = "${service.initialize}";
    systemd.services.nix-dynamic-machines = {
      description = "Dynamic Nix builder registry";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      environment.HOME = config.users.users.root.home;
      serviceConfig = {
        Type = "simple";
        User = "root";
        ExecStart = service.runner;
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 10;
        KillMode = "mixed";
        UMask = "0022";
        StateDirectory = "nix-dynamic-machines";
        StateDirectoryMode = "0755";
      };
    };
  };
}
