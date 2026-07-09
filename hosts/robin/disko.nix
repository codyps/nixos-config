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
              priority = 0;
              type = "EF02";
            };
            boot = {
              size = "2G";
              type = "EF00";
              priority = 1;
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "nofail" ];
              };
            };
            swap = {
              size = "4G";
              priority = 2;
              content = {
                type = "swap";
              };
            };
            zfs = {
              size = "100%";
              priority = 3;
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
            postCreateHook = "zfs list -t snapshot -H -o name robin/root | grep -E '^robin/root@blank$' || zfs snapshot robin/root@blank";
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
