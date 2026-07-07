{
  virtualisation.vmVariantWithDisko = {
    virtualisation.fileSystems."/persist".neededForBoot = true;
  };

  disko.devices = {
    disk = {
      root = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            bios = {
              size = "1M";
              type = "EF02";
            };
            boot = {
              size = "2G";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "nofail" ];
              };
            };
            swap = {
              size = "4G";
              content = {
                type = "swap";
              };
            };
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "robin";
              };
            };
          };
        };
      };
    };
    zpool = {
      robin = {
        type = "zpool";
        rootFsOptions = {
          mountpoint = "none";
          compression = "zstd-fast";
          acltype = "posixacl";
          xattr = "sa";
        };
        options.ashift = "12";
        datasets = {
          "root" = {
            type = "zfs_fs";
            mountpoint = "/";
            postCreateHook = "zfs list -t snapshot -H -o name zroot/root | grep -E '^zroot/root@blank$' || zfs snapshot zroot/root@blank";
          };
          "nix" = {
            type = "zfs_fs";
            options.mountpoint = "/nix";
            mountpoint = "/nix";
          };
          "safe/home" = {
            type = "zfs_fs";
            options.mountpoint = "/home";
            mountpoint = "/home";
          };
          "safe/home/cody" = {
            type = "zfs_fs";
            mountpoint = "/home/cody";
          };
          "safe/persist" = {
            type = "zfs_fs";
            mountpoint = "/persist";
            options.mountpoint = "/persist";
          };
          "safe/syncthing" = {
            type = "zfs_fs";
            mountpoint = "/var/lib/syncthing";
            options.mountpoint = "/var/lib/syncthing";
          };
        };
      };
    };
  };
}
