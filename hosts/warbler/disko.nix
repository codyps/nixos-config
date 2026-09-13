{ ... }:
{
  disko.devices = {
    disk.system = {
      type = "disk";
      # Reconfirm the NVMe's model/capacity before installation; enumeration
      # can change if hardware is added. Do not target the SATA disk.
      device = "/dev/nvme0n1";
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
              # Installation-only file; never a Nix path or initrd keyFile.
              passwordFile = "/tmp/warbler-luks-password";
              extraFormatArgs = [ "--type" "luks2" ];
              content = {
                type = "btrfs";
                subvolumes = {
                  "/root" = {
                    mountpoint = "/";
                    mountOptions = [ "compress=zstd" "noatime" ];
                  };
                  "/nix" = {
                    mountpoint = "/nix";
                    mountOptions = [ "compress=zstd" "noatime" ];
                  };
                  "/persist" = {
                    mountpoint = "/persist";
                    mountOptions = [ "compress=zstd" "noatime" ];
                  };
                  "/home" = {
                    mountpoint = "/home";
                    mountOptions = [ "compress=zstd" "noatime" ];
                  };
                };
              };
            };
          };
        };
      };
    };
  };
}
