{ pkgs, self, ... }:
let
  package = self.packages.${pkgs.stdenv.hostPlatform.system}.dedupit;
in
{
  systemd.services.dedupit = {
    description = "Incrementally deduplicate Warbler's Btrfs filesystem";
    requires = [ "dev-mapper-cryptroot.device" ];
    after = [ "local-fs.target" "dev-mapper-cryptroot.device" ];
    unitConfig.RequiresMountsFor = [ "/var/lib/dedupit" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      StateDirectory = "dedupit";
      StateDirectoryMode = "0700";
      RuntimeDirectory = "dedupit";
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
      # Partial file errors retain pending work. Retry on the next timer tick,
      # without an immediate restart loop against busy executables.
      SuccessExitStatus = [ 2 ];
      TimeoutStartSec = "infinity";
      TimeoutStopSec = "45s";
      Nice = 19;
      IOSchedulingClass = "idle";
      CPUWeight = 10;
      IOWeight = 10;
      MemoryHigh = "2G";
      MemoryMax = "4G";
      PrivateMounts = true;
      NoNewPrivileges = true;
    };
    path = [ pkgs.coreutils pkgs.util-linux ];
    script = ''
      set -euo pipefail
      # A private view has no host/container bind mounts or read-only /nix/store
      # overlay. The top-level tree includes every subvolume exactly once.
      mkdir -p "$RUNTIME_DIRECTORY/filesystem"
      mount -t btrfs -o rw,subvolid=5,nodev,nosuid,noexec \
        /dev/mapper/cryptroot "$RUNTIME_DIRECTORY/filesystem"
      # The private mount is released automatically when the unit exits.
      exec ${pkgs.python3}/bin/python3 ${./dedupit-run.py} \
        --state-directory "$STATE_DIRECTORY" --minimum-free-bytes 5368709120 -- \
        ${package}/bin/dedupit --database "$STATE_DIRECTORY/filesystem.sqlite" \
        --scanner btrfs --chunk-size 1048576 --apply --json \
        "$RUNTIME_DIRECTORY/filesystem"
    '';
  };

  systemd.timers.dedupit = {
    description = "Retry incremental filesystem deduplication hourly";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15min";
      OnUnitInactiveSec = "1h";
      RandomizedDelaySec = "5min";
    };
  };
}
