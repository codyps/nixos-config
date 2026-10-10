{ pkgs, ... }:
{
  # systemd-initrd equivalent of impermanence's Btrfs setup. Persistent
  # subvolumes are siblings of root, never descendants of the deletion target.
  boot.initrd.systemd.services.crow-reset-root = {
    description = "Recreate Crow's ephemeral Btrfs root";
    requiredBy = [ "sysroot.mount" ];
    before = [ "sysroot.mount" ];
    requires = [ "dev-mapper-crow\\x2droot.device" ];
    after = [ "dev-mapper-crow\\x2droot.device" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.btrfs-progs pkgs.util-linux pkgs.coreutils ];
    script = ''
      set -euo pipefail
      mkdir -p /run/crow-btrfs
      mount -t btrfs -o subvolid=5 /dev/mapper/crow-root /run/crow-btrfs
      trap 'umount /run/crow-btrfs' EXIT
      if [[ -e /run/crow-btrfs/root ]]; then
        # Refuse unexpected directories/symlinks; never follow a redirected root.
        test ! -L /run/crow-btrfs/root
        btrfs subvolume show /run/crow-btrfs/root
        btrfs subvolume delete --recursive /run/crow-btrfs/root
      fi
      btrfs subvolume create /run/crow-btrfs/root
    '';
  };
}
