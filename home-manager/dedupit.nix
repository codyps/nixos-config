{ config, lib, pkgs, ... }:

# Unprivileged alternative to nixos-modules/dedupit.nix for hosts that only use
# home-manager (for example the ChromeOS container "penguin"). The whole-volume
# mode of the NixOS module needs root and CAP_SYS_ADMIN to mount the Btrfs
# top-level tree; containers such as Crostini drop those capabilities even for
# root. Instead this runs "dedupit service" as a user unit over directories the
# user can write. Sharing uses the same FIDEDUPERANGE ioctl, which needs no
# privileges, only writable destination files, so deduplication still happens
# natively on Btrfs/XFS(reflink). Discovery is pinned to the portable scanner
# because generation-based Btrfs discovery requires the missing privileges and
# "auto" would log a fallback reason on every run.

let
  cfg = config.services.dedupit;
in
{
  options.services.dedupit = {
    enable = lib.mkEnableOption "incremental deduplication as a systemd user service";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.dedupit;
      description = "Dedupit package providing the native service and statistics commands.";
    };
    roots = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ config.home.homeDirectory ];
      description = "Directories to scan incrementally. Storage is shared only for files this user may write.";
    };
    apply = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Share duplicate ranges using kernel verification; false only records duplicate statistics.";
    };
    databaseStorage = lib.mkOption {
      type = lib.types.enum [ "cow" "nocow" "compressed" "hybrid" ];
      default = "cow";
      description = "Btrfs SQLite policy for the state directory. NOCOW avoids random-write COW amplification.";
    };
    chunkSize = lib.mkOption {
      type = lib.types.ints.between 4096 16777216;
      default = 1048576;
      description = "Logical chunk size in bytes (must be a power of two). Bound to the persistent index.";
    };
    interval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3600;
      description = "Seconds after each run or free-space pause before retrying.";
    };
    minimumFreeBytes = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 5368709120;
      description = "Pause below this much available state-directory space, checked at most every 30 seconds during work.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    systemd.user.services.dedupit = {
      Unit.Description = "Incremental deduplication of user directories";
      Install.WantedBy = [ "default.target" ];
      Service = {
        Type = "simple";
        ExecStart = lib.escapeShellArgs ([
          "${cfg.package}/bin/dedupit"
          "service"
          "--state-directory"
          "%S/dedupit"
          "--scanner"
          "portable"
          "--database-storage"
          cfg.databaseStorage
          "--chunk-size"
          (toString cfg.chunkSize)
          "--interval"
          (toString cfg.interval)
          "--minimum-free-bytes"
          (toString cfg.minimumFreeBytes)
        ] ++ lib.optional cfg.apply "--apply" ++ cfg.roots);
        Restart = "on-failure";
        RestartSec = "5min";
        TimeoutStopSec = "45s";
        StateDirectory = "dedupit";
        StateDirectoryMode = "0700";
        UMask = "0077";
        Nice = 19;
        IOSchedulingClass = "idle";
        CPUWeight = 10;
        IOWeight = 10;
        MemoryHigh = "512M";
        MemoryMax = "1G";
      };
    };
  };
}
