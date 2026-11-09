{ config, lib, pkgs, ... }:
let
  uidBase = config.containers.crow-ai.privateUsers;
  code = pkgs.runCommand "crow-ai-usb-mount-code" { } ''
    mkdir -p "$out"
    cp ${./usb_mount_protocol.py} "$out/usb_mount_protocol.py"
    cp ${./usb-mount-broker.py} "$out/usb-mount-broker.py"
    cp ${./usb-mount-wrapper.py} "$out/usb-mount-wrapper.py"
  '';
  wrappers = pkgs.symlinkJoin {
    name = "crow-ai-usb-mount-wrappers";
    paths = map
      (command: pkgs.writeShellScriptBin command ''
        exec ${pkgs.python3}/bin/python3 -E -s ${code}/usb-mount-wrapper.py \
          ${command} ${pkgs.util-linux}/bin/${command} "$@"
      '')
      [ "mount" "umount" ];
  };
  guide = ''
    Crow AI USB filesystem mounts
    ============================

    USB nodes use normal paths (/dev/sdb1, /dev/hidraw0, /dev/ttyUSB0,
    /dev/ttyACM0, and /dev/bus/usb). Use an existing empty directory
    beneath /mnt or /media, with no symlinks in its path:

      sudo mkdir -p /mnt/usb
      sudo mount /dev/sdb1 /mnt/usb
      sudo umount /mnt/usb

    Substitute the actual partition node. You may also unmount by its
    normal /dev device path. Use -r or -o ro for read-only mounting, and
    optionally -t TYPE or -o noatime. Run sys usb-mount-help for this guide.

    The mount/umount commands delegate these USB operations to a restricted
    host service. Sudo remains confined to the remapped container. Other
    mount operations use the regular util-linux commands locally.

    Supported filesystem types: ext2, ext3, ext4, btrfs, xfs, vfat, exfat,
    ntfs3 (also detected automatically from NTFS), iso9660, and udf, subject
    to host kernel support. POSIX filesystems require ID-mapped mounts;
    existing owners appear as their corresponding guest users. FAT-style
    filesystems use cody-ai ownership. Disk ownership is not rewritten.

    Mounts always have nosuid,nodev,noexec. The helper refuses non-USB
    devices, disks used on the host (including mounted sibling partitions,
    swap, and device-mapper/RAID holders), occupied targets, arbitrary mount
    options, bind/remount requests, network filesystems, LUKS/LVM/RAID, and
    external journals, multi-device/seed Btrfs, registered host Btrfs UUIDs,
    and forced/lazy unmounts. Close files/processes before unmounting, and unmount
    before unplugging. Do not move or overmount helper-managed mountpoints.

    A native filesystem mount is parsed by the shared host kernel; it is
    not safe to treat untrusted filesystem images as isolated from the host.
    The helper checks host usage at request time; coordinate host mounting
    and raw USB writes separately to avoid filesystem corruption.

    If mounting fails, read the error rather than disabling UID remapping
    or trying the underlying mount binary to bypass the helper. USB support
    requires a host rebuild and container restart; it is not provided by
    granting additional capabilities inside the guest.
  '';
in
{
  imports = [ ../../modules/admin-commands.nix ];
  assertions = [{
    assertion = uidBase == 1048576;
    message = "Crow's USB mount broker requires the reserved crow-ai UID mapping.";
  }];
  systemd.sockets.crow-ai-usb-mount = {
    wantedBy = [ "sockets.target" ];
    socketConfig = {
      ListenStream = "/run/crow-ai-usb-mount/control.sock";
      SocketUser = toString uidBase;
      SocketMode = "0600";
      DirectoryMode = "0755";
      RemoveOnStop = true;
    };
  };
  systemd.services.crow-ai-usb-mount = {
    description = "Restricted USB filesystem mount broker for crow-ai";
    requires = [ "crow-ai-usb-mount.socket" ];
    after = [ "crow-ai-usb-mount.socket" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 -E -s ${code}/usb-mount-broker.py ${pkgs.systemd}/bin/machinectl ${pkgs.util-linux}/bin/blkid";
      RuntimeDirectory = "crow-ai-usb-mount-state";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = "yes";
      UMask = "0077";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = false;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      CapabilityBoundingSet = [ "CAP_SYS_ADMIN" "CAP_SYS_CHROOT" "CAP_SYS_PTRACE" "CAP_DAC_OVERRIDE" "CAP_DAC_READ_SEARCH" ];
      TasksMax = 16;
      MemoryMax = "256M";
      LimitNOFILE = 128;
    };
  };
  systemd.services."container@crow-ai" = {
    requires = [ "crow-ai-usb-mount.socket" ];
    after = [ "crow-ai-usb-mount.socket" ];
  };
  containers.crow-ai = {
    bindMounts."/run/crow-ai-usb-mount" = {
      hostPath = "/run/crow-ai-usb-mount";
      isReadOnly = true;
    };
    config = {
      imports = [ ../../modules/admin-commands.nix ];
      environment.systemPackages = [ (lib.hiPrio wrappers) ];
      # /run/wrappers/bin precedes the system profile in sudo's PATH. Disable
      # those setuid entry points so sudo finds our ordinary system wrappers.
      security.wrappers = lib.genAttrs [ "mount" "umount" ] (_: {
        enable = lib.mkForce false;
      });
      environment.etc."crow-ai-usb-mounts.md".text = guide;
      users.motd = "USB mounts: sudo mount /dev/DEVICE /mnt/usb; help: sys usb-mount-help\n";
      programs.adminCommands.commands.usb-mount-help = [ "${pkgs.coreutils}/bin/cat" "/etc/crow-ai-usb-mounts.md" ];
    };
  };
}
