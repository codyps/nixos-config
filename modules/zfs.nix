{ config, pkgs, lib, ... }:
let
  cfg = config.p.zfs;
  zfs = config.boot.zfs.package;
in
{
  options.p.zfs.root-impermenance = {
    enable = lib.mkEnableOption "enable root-impermenance";
    rollback-target = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        zfs rollback target `<dataset>@<snapshot>` for impermenance
      '';
    };
  };

  config = lib.mkMerge [
    ({
      environment.persistence."/persist" = {
        directories = [
          "/etc/zfs/zfs-list.cache"
        ];
        files = [
          "/etc/machine-id"
          "/etc/zfs/zpool.cache"
        ];
      };

      #boot.initrd.extraFiles."/etc/zfs/zfs-list.cache".source = /persist/etc/zfs/zfs-list.cache;
      #boot.initrd.extraFiles."/etc/zfs/zpool.cache".source = /persist/etc/zfs/zpool.cache;

      services.zfs.zed.settings.PATH = lib.mkForce (lib.makeBinPath [
        pkgs.diffutils
        zfs
        pkgs.coreutils
        pkgs.curl
        pkgs.gawk
        pkgs.gnugrep
        pkgs.gnused
        pkgs.nettools
        pkgs.util-linux
      ]);

      services.udev.extraRules = ''
        KERNEL=="sd[a-z]*[0-9]*|mmcblk[0-9]*p[0-9]*|nvme[0-9]*n[0-9]*p[0-9]*|xvd[a-z]*[0-9]*", ENV{ID_FS_TYPE}=="zfs_member", ATTR{../queue/scheduler}="none"
      '';

      systemd.generators."zfs-mount-generator" = "${zfs}/lib/systemd/system-generator/zfs-mount-generator";
      environment.etc."zfs/zed.d/history_event-zfs-list-cacher.sh".source = "${zfs}/etc/zfs/zed.d/history_event-zfs-list-cacher.sh";
      systemd.services.zfs-mount.enable = false;

      services.zfs.autoScrub = {
        enable = true;
        interval = "monthly";
      };
    })

    (lib.mkIf cfg.root-impermenance.enable
      {
        boot.initrd.systemd.enable = lib.mkDefault true;
        boot.initrd.systemd.services.rollback =
          let
            pool = builtins.elemAt (lib.splitString "/" cfg.root-impermenance.rollback-target) 0;
          in
          {
            description = "Rollback root filesystem to a pristine state on boot";
            wantedBy = [
              # "zfs.target"
              "initrd.target"
            ];
            after = [
              "zfs-import-${pool}.service"
            ];
            requires = [
              "zfs-import-${pool}.service"
            ];
            before = [
              "sysroot.mount"
              # from impermenance
              "create-needed-for-boot-dirs.service"
            ];
            path = [
              zfs
            ];
            unitConfig.DefaultDependencies = "no";
            serviceConfig.Type = "oneshot";
            script = ''
              zfs rollback -r ${cfg.root-impermenance.rollback-target} && echo "  >> >> rollback complete << <<"
            '';
          };
      })
  ];
}
