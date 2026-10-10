{ ... }:
{
  disko.devices = {
    disk.system = {
      type = "disk";
      # Inspected on the installer: WD_BLACK SN850X 4000GB. Formatting erases NTFS.
      device = "/dev/disk/by-id/${(import ../../lib/hardware-identities.nix) "crow" "installDiskId"}";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            priority = 1;
            size = "2G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          crypt = {
            size = "100%";
            content = {
              type = "luks";
              name = "cryptroot";
              passwordFile = "/run/crow-luks-password";
              extraFormatArgs = [ "--type" "luks2" ];
              content = { type = "lvm_pv"; vg = "crow"; };
            };
          };
        };
      };
    };
    lvm_vg.crow = {
      type = "lvm_vg";
      lvs = {
        root = {
          # LVM accepts bytes with the B suffix and rounds to whole extents.
          size = "1000000000000B";
          content = {
            type = "btrfs";
            subvolumes = {
              "/root" = { mountpoint = "/"; mountOptions = [ "compress=zstd" "noatime" ]; };
              "/nix" = { mountpoint = "/nix"; mountOptions = [ "compress=zstd" "noatime" ]; };
              "/persist" = { mountpoint = "/persist"; mountOptions = [ "compress=zstd" "noatime" ]; };
              "/home" = { mountpoint = "/home"; mountOptions = [ "compress=zstd" "noatime" ]; };
            };
          };
        };
        swap = { size = "8G"; content.type = "swap"; };
        # Leave the remaining extents free for later LV expansion/allocation.
      };
    };
  };
}
