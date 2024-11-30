{ config, pkgs, lib }:
  options = {
    p = {
      # 
      zfs-root-impermenance = {
        roolback-target = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = ''
            zfs rollback target `<dataset>@<snapshot>` for impermenance
          '';
        };
      };
    };
  };

  config = {
    environment.persistence."/persist" = {
      directories = [
        "/etc/zfs/zfs-list.cache"
      ];
      files = [
        "/etc/machine-id"
        "/etc/zfs/zpool.cache"
      ];
    };

    boot.initrd.extraFiles."/etc/zfs/zfs-list.cache".source = /persist/etc/zfs/zfs-list.cache;
    boot.initrd.extraFiles."/etc/zfs/zpool.cache".source = /persist/etc/zfs/zpool.cache;

    boot.initrd.systemd.services.rollback = {
      description = "Rollback root filesystem to a pristine state on boot";
      wantedBy = [
        # "zfs.target"
        "initrd.target"
      ];
      after = [
        # FIXME: parse out pool name
        "zfs-import-rpool.service"
      ];
      before = [
        "sysroot.mount"
      ];
      path = with pkgs; [
        zfs
      ];
      unitConfig.DefaultDependencies = "no";
      serviceConfig.Type = "oneshot";
      script = ''
        zfs rollback -r ${config.p.zfs-root-impermenance.rollback-target} && echo "  >> >> rollback complete << <<"
      '';
    };

    services.zfs.zed.settings.PATH = lib.mkForce (lib.makeBinPath [
      pkgs.diffutils
      config.boot.zfs.package
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

    systemd.generators."zfs-mount-generator" = "${config.boot.zfs.package}/lib/systemd/system-generator/zfs-mount-generator";
    environment.etc."zfs/zed.d/history_event-zfs-list-cacher.sh".source = "${config.boot.zfs.package}/etc/zfs/zed.d/history_event-zfs-list-cacher.sh";
    systemd.services.zfs-mount.enable = false;

    services.zfs.autoScrub = {
      enable = true;
      interval = "monthly";
    };
  };
}
