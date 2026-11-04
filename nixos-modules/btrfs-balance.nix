{ config, lib, pkgs, ... }:
let
  cfg = config.services.btrfs.autoBalance;
  btrfsMounts = lib.attrNames (lib.filterAttrs (_: fs: fs.fsType == "btrfs") config.fileSystems);
in
{
  options.services.btrfs.autoBalance = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = btrfsMounts != [ ];
      defaultText = lib.literalExpression "any configured filesystem uses Btrfs";
      description = "Schedule limited Btrfs data-block-group reclamation.";
    };
    fileSystems = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = btrfsMounts;
      description = "Configured mount points to inspect; each mounted writable Btrfs UUID is processed once.";
    };
    interval = lib.mkOption {
      type = lib.types.str;
      default = "weekly";
      description = "Calendar schedule for Btrfs block-group reclamation.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.btrfs-balance = {
      description = "Reclaim empty and lightly used Btrfs block groups";
      after = [ "local-fs.target" ];
      path = [ pkgs.btrfs-progs pkgs.util-linux ];
      script = ''
        exec ${pkgs.python3}/bin/python3 ${../scripts/btrfs-balance.py} ${lib.escapeShellArgs cfg.fileSystems}
      '';
      serviceConfig = {
        Type = "oneshot";
        Nice = 19;
        IOSchedulingClass = "idle";
        CPUWeight = 10;
        IOWeight = 10;
        TimeoutStartSec = "12h";
      };
    };
    systemd.timers.btrfs-balance = {
      description = "Schedule limited Btrfs balance maintenance";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        RandomizedDelaySec = "2h";
        Persistent = true;
      };
    };
  };
}
