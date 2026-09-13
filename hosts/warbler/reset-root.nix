{ pkgs, ... }:
{
  # systemd-initrd equivalent of impermanence's Btrfs setup. Persistent
  # subvolumes are siblings of root, never descendants of the deletion target.
  boot.initrd.systemd.services.warbler-reset-root = {
    description = "Recreate Warbler's ephemeral Btrfs root";
    requiredBy = [ "sysroot.mount" ];
    before = [ "sysroot.mount" ];
    requires = [ "dev-mapper-cryptroot.device" ];
    after = [ "dev-mapper-cryptroot.device" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.btrfs-progs pkgs.util-linux pkgs.coreutils ];
    script = ''
      set -euo pipefail
      mkdir -p /run/warbler-btrfs
      mount -t btrfs -o subvolid=5 /dev/mapper/cryptroot /run/warbler-btrfs
      trap 'umount /run/warbler-btrfs' EXIT
      if [[ -e /run/warbler-btrfs/root ]]; then
        # Refuse unexpected directories/symlinks; never follow a redirected root.
        test ! -L /run/warbler-btrfs/root
        btrfs subvolume show /run/warbler-btrfs/root
        btrfs subvolume delete --recursive /run/warbler-btrfs/root
      fi
      btrfs subvolume create /run/warbler-btrfs/root
    '';
  };
}
