{ pkgs }:
let
  rootUUID = "2a0c4c80-ec29-40c9-aeb9-780610e01364";
  rpc = pkgs.writeShellScriptBin "vmware-rpctool" ''
    echo "$1" >> /run/reclaim-rpc.log
    case "$1" in
      disk.wiper.enable)
        if test -e /run/reclaim-disabled; then echo 0; else echo 1; fi
        ;;
      disk.shrink)
        test ! -e /run/reclaim-shrink-error
        ;;
      *) exit 1 ;;
    esac
  '';
  fsck = pkgs.writeShellScriptBin "e2fsck" ''
    if test -e /run/reclaim-fsck-error; then exit 4; fi
    exec ${pkgs.e2fsprogs}/bin/e2fsck "$@"
  '';
  reclaim = pkgs.writeShellApplication {
    name = "test-reclaim-space";
    runtimeInputs = [ rpc fsck pkgs.e2fsprogs pkgs.zerofree pkgs.util-linux pkgs.gawk pkgs.coreutils ];
    text = builtins.readFile ./reclaim-space.sh;
  };
in
pkgs.testers.runNixOSTest {
  name = "mifflin-reclaim-space";
  nodes.machine = {
    virtualisation.emptyDiskImages = [ 64 16 ];
    environment.systemPackages = [ reclaim pkgs.e2fsprogs pkgs.zerofree ];
  };
  nodes.initrd = { lib, ... }: {
    imports = [ ./reclaim-space-initrd.nix ];
    virtualisation.rootDevice = "/dev/disk/by-uuid/${rootUUID}";
    virtualisation.diskSize = 128;
    fileSystems."/".autoResize = lib.mkForce false;
    boot.initrd.systemd.extraBin.vmware-rpctool = lib.mkForce "${rpc}/bin/vmware-rpctool";
    # The test driver creates the blank root disk with a random UUID. Give it
    # the expected UUID before the real maintenance service waits for it.
    boot.initrd.systemd.services.prepare-reclaim-test-root = {
      requiredBy = [ "mifflin-reclaim-space.service" ];
      before = [ "mifflin-reclaim-space.service" ];
      requires = [ "dev-vda.device" ];
      after = [ "dev-vda.device" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig.Type = "oneshot";
      path = [ pkgs.e2fsprogs pkgs.systemd ];
      script = ''
        tune2fs -U ${rootUUID} /dev/vda
        udevadm trigger --action=change /sys/class/block/vda
        udevadm settle
      '';
    };
  };
  testScript = ''
    import re

    with subtest("maintenance initrd completes before mounting root"):
        initrd.start()
        initrd.wait_for_unit("multi-user.target")
        assert initrd.succeed("cat /run/reclaim-rpc.log").splitlines() == ["disk.wiper.enable", "disk.shrink"]
        initrd.succeed("journalctl -b -u mifflin-reclaim-space.service | grep -q 'Fusion compaction completed'")

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkfs.ext4 -F -U ${rootUUID} /dev/vdb")
    machine.succeed("mkswap /dev/vdc")
    machine.succeed("mkdir -p /mnt/reclaim && mount /dev/vdb /mnt/reclaim")
    machine.succeed("dd if=/dev/urandom of=/mnt/reclaim/keep bs=1M count=2 status=none")
    machine.succeed("cp /mnt/reclaim/keep /mnt/reclaim/deleted && sync")
    kept_hash = machine.succeed("sha256sum /mnt/reclaim/keep").split()[0]
    machine.succeed("rm /mnt/reclaim/deleted && sync")
    command = "test-reclaim-space /dev/vdb ${rootUUID} /dev/vdc"

    with subtest("mounted aliases are refused"):
        machine.succeed("ln -s /dev/vdb /dev/reclaim-alias")
        machine.fail("test-reclaim-space /dev/reclaim-alias ${rootUUID} /dev/vdc")
        machine.succeed("test ! -e /run/reclaim-rpc.log")
    machine.succeed("umount /mnt/reclaim")

    def disk_hash():
        return machine.succeed("sha256sum /dev/vdb").split()[0]

    before = disk_hash()
    with subtest("wrong identity and active swap are refused without writes"):
        machine.fail("test-reclaim-space /dev/vdb wrong-uuid /dev/vdc")
        machine.succeed("swapon /dev/vdc")
        machine.fail(command)
        machine.succeed("swapoff /dev/vdc")
        assert disk_hash() == before

    with subtest("hibernated swap is refused without modifying root"):
        machine.succeed("printf S1SUSPEND | dd of=/dev/vdc bs=1 seek=4086 conv=notrunc status=none")
        machine.fail(command)
        assert disk_hash() == before
        machine.succeed("mkswap /dev/vdc")

    with subtest("disabled host and failed fsck cannot reach zeroing or shrink"):
        machine.succeed("touch /run/reclaim-disabled")
        machine.fail(command)
        machine.succeed("rm /run/reclaim-disabled && touch /run/reclaim-fsck-error")
        machine.fail(command)
        assert disk_hash() == before
        machine.succeed("! grep -qx disk.shrink /run/reclaim-rpc.log")
        machine.succeed("rm /run/reclaim-fsck-error")

    with subtest("free blocks are zeroed and live files are preserved"):
        result = machine.succeed("zerofree -nv /dev/vdb 2>/dev/null").strip()
        match = re.search(r"(\d+)/(\d+)/(\d+)", result)
        assert match is not None and int(match.group(1)) > 0
        machine.succeed("rm /run/reclaim-rpc.log")
        machine.succeed(command)
        assert machine.succeed("cat /run/reclaim-rpc.log").splitlines() == ["disk.wiper.enable", "disk.shrink"]
        result = machine.succeed("zerofree -nv /dev/vdb 2>/dev/null").strip()
        match = re.search(r"(\d+)/(\d+)/(\d+)", result)
        assert match is not None and int(match.group(1)) == 0
        machine.succeed("e2fsck -fn /dev/vdb")
        machine.succeed("mount /dev/vdb /mnt/reclaim")
        assert machine.succeed("sha256sum /mnt/reclaim/keep").split()[0] == kept_hash
        machine.succeed("test ! -e /mnt/reclaim/deleted && umount /mnt/reclaim")

    with subtest("compaction failure is returned after completed zeroing"):
        machine.succeed("touch /run/reclaim-shrink-error")
        machine.fail(command + " > /run/reclaim-failure.log 2>&1")
        machine.succeed("grep -q 'Zeroing completed, but Fusion compaction failed' /run/reclaim-failure.log")
  '';
}
