{ config, lib, pkgs, utils, ... }:

let
  root = config.fileSystems."/";
  uuidPrefix = "/dev/disk/by-uuid/";
  swapDevices = map (swap: swap.device) config.swapDevices;
  deviceUnits = map (device: "${utils.escapeSystemdPath device}.device")
    ([ root.device ] ++ swapDevices);
in
{
  system.nixos.tags = [ "reclaim-space" ];
  boot.initrd.systemd.enable = true;
  boot.resumeDevice = lib.mkForce "";
  boot.kernelParams = [ "noresume" ];

  assertions = [
    {
      assertion = root.fsType == "ext4" && lib.hasPrefix uuidPrefix root.device;
      message = "Mifflin reclaim-space requires an ext4 root identified by filesystem UUID.";
    }
    {
      assertion = !root.autoResize;
      message = "Disable root autoResize before using the reclaim-space entry.";
    }
    {
      assertion = lib.all (swap: swap.isDevice && !swap.randomEncryption.enable) config.swapDevices;
      message = "Mifflin reclaim-space supports only plain swap partitions, which it checks for hibernation images.";
    }
  ];

  # This entry owns the full check before zerofree. Set fstab's pass to zero
  # to avoid a redundant check; also order after any root check emitted by
  # the initrd generator, which can still create one independently of fstab.
  fileSystems."/".noCheck = lib.mkForce true;

  boot.initrd.systemd = {
    # Copy the individual programs and their libraries, not the entire
    # desktop VMware Tools package, into the small EFI boot partition.
    extraBin = {
      bash = "${pkgs.bashNonInteractive}/bin/bash";
      awk = "${pkgs.gawk}/bin/awk";
      blkid = "${pkgs.util-linux}/bin/blkid";
      lsblk = "${pkgs.util-linux}/bin/lsblk";
      sync = "${pkgs.coreutils}/bin/sync";
      e2fsck = "${pkgs.e2fsprogs}/bin/e2fsck";
      zerofree = "${pkgs.zerofree}/bin/zerofree";
      vmware-rpctool = "${pkgs.open-vm-tools}/bin/vmware-rpctool";
    };
    storePaths = [ "${./reclaim-space.sh}" ];
    services.mifflin-reclaim-space = {
      description = "Zero unallocated ext4 blocks and compact VMware disks";
      requiredBy = [ "sysroot.mount" ];
      before = [ "sysroot.mount" "swap.target" ];
      requires = deviceUnits;
      after = deviceUnits ++ [
        "systemd-fsck@${utils.escapeSystemdPath root.device}.service"
        "systemd-fsck-root.service"
      ];
      onFailure = [ "emergency.target" ];
      unitConfig = {
        DefaultDependencies = false;
        ConditionPathExists = "/etc/initrd-release";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "infinity";
        StandardOutput = "journal+console";
        StandardError = "journal+console";
        ExecStart = "/bin/bash ${./reclaim-space.sh} ${lib.escapeShellArgs ([ root.device (lib.removePrefix uuidPrefix root.device) ] ++ swapDevices)}";
      };
    };
  };
}
