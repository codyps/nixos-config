{ config, lib, pkgs, ... }:
let
  cfg = config.services.nix-dynamic-machines;
  service = import ../../modules/nix-dynamic-machines-service.nix {
    inherit config lib pkgs;
    directory = "/var/db/nix-dynamic-machines";
  };
in
{
  imports = [ ../../modules/nix-dynamic-machines.nix ];

  config = lib.mkIf cfg.enable {
    nix.settings.builders = service.builders;
    system.activationScripts.preActivation.text = "${service.initialize}";
    launchd.daemons.nix-dynamic-machines = {
      environment.HOME = "/var/root";
      serviceConfig = {
        ProgramArguments = [ "${service.runner}" ];
        UserName = "root";
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 5;
        ExitTimeOut = 10;
        StandardOutPath = "/var/log/nix-dynamic-machines.log";
        StandardErrorPath = "/var/log/nix-dynamic-machines.log";
      };
    };
  };
}
