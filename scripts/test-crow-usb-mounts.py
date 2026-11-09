#!/usr/bin/env python3
"""Policy, wrapper routing, and Linux mount API tests; no physical disks used."""

import array
import errno
import importlib.util
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch, Mock

CODE = Path(__file__).resolve().parents[1] / "hosts/crow"
sys.path.insert(0, str(CODE))
from usb_mount_protocol import Rejected, validate_request


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, CODE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


broker = load("broker", "usb-mount-broker.py")
wrapper = load("wrapper", "usb-mount-wrapper.py")
layout = load("layout", "usb-dev-layout.py")


def mount_request(**changes):
    return dict(op="mount", source="/dev/synthetic1", target="/mnt/usb", fstype=None, options=[]) | changes


class PolicyTests(unittest.TestCase):
    def test_rejects_paths_options_and_types_that_expand_host_authority(self):
        invalid = [
            dict(source="/sys/synthetic1"), dict(source="/dev/../../internal"),
            dict(source="/dev/by-id/example"), dict(target="/etc"),
            dict(target="/mnt/../etc"), dict(target="/mnt//usb"), dict(target="/mnt/usb/"),
            dict(options=["bind"]), dict(options=["remount"]), dict(options=["suid"]),
            dict(options=["dev"]), dict(options=["exec"]), dict(options=["uid=0"]),
            dict(options=["loop"]), dict(options=["ro", "rw"]), dict(options="ro"),
            dict(fstype="nfs"), dict(fstype="overlay"), dict(fstype=[]), dict(extra="ignored"),
        ]
        for changes in invalid:
            with self.subTest(changes=changes), self.assertRaises(Rejected):
                validate_request(mount_request(**changes))
        self.assertEqual(validate_request(mount_request(options=["ro", "noatime"]))["options"], ["ro", "noatime"])

    def test_wrappers_delegate_usb_but_keep_other_mounts_local(self):
        with patch.object(wrapper.os, "stat", return_value=Mock(st_mode=0o060000)):
            self.assertEqual(wrapper.request_for("mount", ["-r", "/dev/synthetic1", "/mnt/usb"])["options"], ["ro"])
        self.assertEqual(wrapper.request_for("umount", ["/dev/synthetic1"])["op"], "umount")
        self.assertEqual(wrapper.request_for("umount", ["/mnt/usb"])["target"], "/mnt/usb")
        self.assertIsNone(wrapper.request_for("mount", ["-t", "tmpfs", "tmpfs", "/tmp/local"]))
        self.assertIsNone(wrapper.request_for("mount", []))
        self.assertIsNone(wrapper.request_for("mount", ["--bind", "/dev/null", "/tmp/node"]))
        self.assertIsNone(wrapper.request_for("umount", ["/tmp/local"]))
        with patch("sys.stderr"), self.assertRaises(SystemExit):
            wrapper.request_for("umount", ["-l", "/mnt/usb"])

    def test_rejects_wrong_user_before_any_machine_or_device_access(self):
        with patch.object(broker.subprocess, "check_output") as machine:
            with self.assertRaises(Rejected):
                broker.Guest(123, broker.UID_BASE + 1001, "unused-machinectl")
            machine.assert_not_called()

    def test_rejects_an_unremapped_container_and_a_peer_in_another_namespace(self):
        with patch.object(broker.subprocess, "check_output", return_value=str(os.getpid())):
            with patch.object(broker.os, "read", return_value=b"0 0 65536\n"), self.assertRaises(Rejected):
                broker.Guest(os.getpid(), broker.UID_BASE, "unused")
            real_stat = os.stat
            def peer_stat(path, *args, **kwargs):
                if str(path).startswith("/proc/99999999/ns/"):
                    return Mock(st_ino=-1)
                return real_stat(path, *args, **kwargs)
            mapping = f"0 {broker.UID_BASE} {broker.UID_COUNT}\n".encode()
            with patch.object(broker.os, "read", return_value=mapping), patch.object(broker.os, "stat", side_effect=peer_stat):
                with self.assertRaises(Rejected):
                    broker.Guest(99999999, broker.UID_BASE, "unused")

    def test_rejects_oversized_and_malformed_protocol_messages(self):
        for content in (b"x" * 4097, b"not json\n"):
            a, b = socket.socketpair()
            with a, b:
                a.sendall(content)
                with self.assertRaises((Rejected, ValueError)):
                    broker.receive(b)


class HostDevicePolicyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.disk = self.root / "usb-device" / "disk"
        self.partition = self.disk / "partition"
        self.partition.mkdir(parents=True)
        for node, number in ((self.disk, "240:0"), (self.partition, "240:1")):
            (node / "dev").write_text(number)
            (node / "holders").mkdir()
        (self.partition / "partition").write_text("1")
        (self.disk.parent / "subsystem").symlink_to("/sys/bus/usb")

    def test_usb_ancestry_uses_sysfs_not_device_name(self):
        self.assertEqual(broker.usb_disk(self.partition), self.disk)
        (self.disk.parent / "subsystem").unlink()
        (self.disk.parent / "subsystem").symlink_to("/sys/bus/pci")
        with self.assertRaises(Rejected):
            broker.usb_disk(self.partition)

    def test_mounted_sibling_and_device_mapper_holders_are_rejected(self):
        with patch.object(Path, "glob", return_value=[]):
            broker.check_disk_unused(self.disk, "", "Filename Type Size Used Priority\n")
            with self.assertRaises(Rejected):
                broker.check_disk_unused(self.disk, "1 0 240:1 / /host rw - ext4 /dev/example rw", "")
            (self.partition / "holders" / "synthetic-dm").touch()
            with self.assertRaises(Rejected):
                broker.check_disk_unused(self.disk, "", "")

    def test_btrfs_anonymous_mount_device_does_not_bypass_usage_check(self):
        member = self.root / "btrfs-member-dev"
        member.write_text("240:1")
        with patch.object(Path, "glob", return_value=[member]), self.assertRaises(Rejected):
            broker.check_disk_unused(self.disk, "1 0 0:99 / /host rw - btrfs /dev/example rw", "")

    def test_swap_block_devices_are_rejected(self):
        fake_swap = Mock(st_mode=0o060000, st_rdev=os.makedev(240, 1))
        real_stat = os.stat
        def swap_stat(path, *args, **kwargs):
            return fake_swap if str(path) == "/dev/synthetic" else real_stat(path, *args, **kwargs)
        with patch.object(Path, "glob", return_value=[]), patch.object(broker.os, "stat", side_effect=swap_stat):
            with self.assertRaises(Rejected):
                broker.check_disk_unused(self.disk, "", "Filename Type Size Used Priority\n/dev/synthetic partition 1 0 -2\n")


class BrokerStateTests(unittest.TestCase):
    def test_restarts_retain_managed_mounts_and_drop_only_dead_namespace_mounts(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            first = broker.Broker("unused", "unused", state)
            first.records = [dict(namespace=10, mount_id=20, target="/mnt/usb"), dict(namespace=10, mount_id=21)]
            first.save()
            second = broker.Broker("unused", "unused", state)
            guest = Mock(identity=10)
            guest.mount_ids.return_value = {20}
            second.prune(guest)
            self.assertEqual(second.records, [dict(namespace=10, mount_id=20, target="/mnt/usb")])
            self.assertEqual(state.stat().st_mode & 0o777, 0o600)

    def test_unmount_does_not_act_on_a_replaced_mount(self):
        instance = broker.Broker("unused", "unused", Path("/nonexistent-crow-test-state"))
        instance.records = [dict(target="/mnt/usb", source="/dev/synthetic1", mount_id=10)]
        guest = Mock()
        guest.target.return_value = (100, 101, "usb")
        with patch.object(broker, "mount_id", return_value=11), patch.object(broker.os, "close") as close:
            with self.assertRaises(Rejected):
                instance.unmount(guest, "/mnt/usb")
            self.assertEqual(close.call_count, 2)
        guest.unmount.assert_not_called()


class DeviceLayoutTests(unittest.TestCase):
    def test_hotplug_normal_names_and_collision_protection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, dev, state = root / "mirror", root / "dev", root / "state/links.json"
            source.mkdir()
            dev.mkdir()
            for name in ("sdb1", "hidraw0", "ttyUSB0", "input/event0", "bus/usb/001/002", "null"):
                node = source / name
                node.parent.mkdir(parents=True, exist_ok=True)
                node.write_text("synthetic device")
            (dev / "null").write_text("existing container device")
            (source / "foreign-link").symlink_to("/dev/null")
            original = layout.stat.S_ISCHR
            # Synthetic regular files stand in for char nodes; no real device
            # identifiers, privileged mknod calls, or physical devices are used.
            with patch.object(layout.stat, "S_ISCHR", side_effect=lambda mode: layout.stat.S_ISREG(mode) or original(mode)):
                layout.sync(source, dev, state)
                for name in ("sdb1", "hidraw0", "ttyUSB0", "input/event0"):
                    self.assertEqual((dev / name).readlink(), source / name)
                self.assertFalse((dev / "bus").exists())
                self.assertFalse((dev / "foreign-link").exists())
                self.assertEqual((dev / "null").read_text(), "existing container device")
                (source / "hidraw0").unlink()
                layout.sync(source, dev, state)
                self.assertFalse(os.path.lexists(dev / "hidraw0"))
                # Do not remove replacements owned by another guest program.
                (dev / "ttyUSB0").unlink()
                (dev / "ttyUSB0").write_text("replacement")
                (source / "ttyUSB0").unlink()
                layout.sync(source, dev, state)
                self.assertEqual((dev / "ttyUSB0").read_text(), "replacement")

    def test_does_not_follow_guest_parent_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, dev, outside = root / "mirror", root / "dev", root / "outside"
            (source / "input").mkdir(parents=True)
            (source / "input/event0").write_text("synthetic device")
            dev.mkdir()
            outside.mkdir()
            (dev / "input").symlink_to(outside)
            with patch.object(layout.stat, "S_ISCHR", return_value=True):
                layout.sync(source, dev, root / "state.json")
            self.assertEqual(list(outside.iterdir()), [])


class FilesystemPolicyTests(unittest.TestCase):
    def test_ext_external_journals_are_rejected_before_mounting(self):
        data = bytearray(2048)
        data[1024 + 0x38:1024 + 0x3a] = b"\x53\xef"
        struct.pack_into("<I", data, 1024 + 0x5c, 4)
        struct.pack_into("<I", data, 1024 + 0xe0, 8)
        with tempfile.TemporaryFile() as source:
            source.write(data)
            source.flush()
            broker.check_filesystem(source.fileno(), "ext4")
            for offset, value in ((0xe4, 1), (0xe0, 0), (0x60, 8)):
                altered = bytearray(data)
                struct.pack_into("<I", altered, 1024 + offset, value)
                source.seek(0)
                source.write(altered)
                source.flush()
                with self.subTest(offset=offset), self.assertRaises(Rejected):
                    broker.check_filesystem(source.fileno(), "ext4")

    def test_btrfs_requires_one_device_and_no_host_registration_or_seed(self):
        data = bytearray(65536 + 4096)
        data[65536 + 0x40:65536 + 0x48] = b"_BHRfS_M"
        struct.pack_into("<Q", data, 65536 + 0x88, 1)
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryFile() as source:
            registry = Path(directory)
            source.write(data)
            source.flush()
            broker.check_filesystem(source.fileno(), "btrfs", registry)
            for offset, value in ((0x88, 2), (0x38, 1 << 32), (0xbc, 1 << 10)):
                altered = bytearray(data)
                struct.pack_into("<Q", altered, 65536 + offset, value)
                source.seek(0)
                source.write(altered)
                source.flush()
                with self.subTest(offset=offset), self.assertRaises(Rejected):
                    broker.check_filesystem(source.fileno(), "btrfs", registry)
            source.seek(0)
            source.write(data)
            source.flush()
            (registry / str(broker.uuid.UUID(int=0))).mkdir()
            with self.assertRaises(Rejected):
                broker.check_filesystem(source.fileno(), "btrfs", registry)


def child_guest_namespaces(root):
    parent, child = socket.socketpair()
    pid = os.fork()
    if pid == 0:
        parent.close()
        try:
            broker.checked(broker.LIBC.unshare(0x10000000))
            Path("/proc/self/setgroups").write_text("deny")
            Path("/proc/self/uid_map").write_text("0 0 1")
            Path("/proc/self/gid_map").write_text("0 0 1")
            broker.checked(broker.LIBC.unshare(broker.CLONE_NEWNS))
            userfd = os.open("/proc/self/ns/user", os.O_RDONLY)
            mountfd = os.open("/proc/self/ns/mnt", os.O_RDONLY)
            os.chroot(root)
            os.chdir("/")
            rootfd = os.open("/", broker.O_PATH | os.O_DIRECTORY)
            child.sendmsg([b"n"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [userfd, mountfd, rootfd]))])
            os._exit(0)
        except BaseException:
            os._exit(1)
    child.close()
    _, ancillary, _, _ = parent.recvmsg(1, socket.CMSG_SPACE(12))
    _, status = os.waitpid(pid, 0)
    parent.close()
    if status or not ancillary:
        raise RuntimeError("Cannot create test user namespace")
    fds = array.array("i")
    fds.frombytes(ancillary[0][2][:12])
    return fds


def kernel_worker(directory):
    """Actually mount/unmount tmpfs through the broker's kernel operations."""
    root = Path(directory)
    (root / "mnt/usb").mkdir(parents=True)
    (root / "mnt/symlink").symlink_to("/etc")
    guest = broker.Guest.__new__(broker.Guest)
    super(broker.Guest, guest).__init__()
    with guest:
        userfd, mountfd, rootfd = child_guest_namespaces(root)
        userns = guest.keep(userfd)
        guest.root = guest.keep(rootfd)
        guest.mountns = guest.keep(mountfd)
        try:
            broker.open_beneath(guest.root, "/mnt/symlink")
        except OSError as error:
            assert error.errno == errno.ELOOP
        else:
            raise AssertionError("openat2 followed a symlink")
        parentfd, targetfd, name = guest.target("/mnt/usb", empty=True)
        fd = broker.detached_mount("tmpfs", parameters=[("mode", "0700")], userns=userns)
        original_id = broker.mount_id(fd)
        guest.attach(fd, targetfd)
        os.close(fd)
        os.close(targetfd)
        mounted = broker.open_beneath(guest.root, "/mnt/usb")
        assert broker.mount_id(mounted) == original_id
        required_flags = os.ST_NOSUID | os.ST_NODEV | os.ST_NOEXEC
        assert os.statvfs(f"/proc/self/fd/{mounted}").f_flag & required_flags == required_flags
        # A busy filesystem must remain mounted; forced/lazy detach is not used.
        try:
            guest.unmount(parentfd, name)
        except Rejected:
            pass
        else:
            raise AssertionError("busy filesystem was unmounted")
        marker = os.open("marker", os.O_WRONLY | os.O_CREAT, 0o600, dir_fd=mounted)
        os.write(marker, b"inside private tmpfs")
        os.close(marker)
        os.close(mounted)
        # The mount exists only in the separate guest namespace.
        assert not (root / "mnt/usb/marker").exists()
        try:
            guest.target("/mnt/usb", empty=True)
        except Rejected:
            pass
        else:
            raise AssertionError("occupied mountpoint accepted")
        guest.unmount(parentfd, name)
        os.close(parentfd)
        assert not (root / "mnt/usb/marker").exists()
        parentfd, targetfd, name = guest.target("/mnt/usb", empty=True)
        fd = broker.detached_mount("tmpfs", readonly=True, userns=userns)
        guest.attach(fd, targetfd)
        os.close(fd)
        os.close(targetfd)
        mounted = broker.open_beneath(guest.root, "/mnt/usb")
        try:
            os.open("should-not-write", os.O_WRONLY | os.O_CREAT, 0o600, dir_fd=mounted)
        except OSError as error:
            assert error.errno == errno.EROFS
        else:
            raise AssertionError("read-only mount allowed a write")
        os.close(mounted)
        guest.unmount(parentfd, name)
        os.close(parentfd)


class LinuxNamespaceTests(unittest.TestCase):
    def test_kernel_idmapped_mount_attach_symlink_rejection_and_unmount(self):
        unshare = shutil.which("unshare")
        if unshare is None:
            self.skipTest("unshare is unavailable on this runner")
        probe = subprocess.run([unshare, "--user", "--map-root-user", "--mount", "true"], capture_output=True)
        if probe.returncode:
            self.skipTest("User/mount namespaces are unavailable on this runner")
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [unshare, "--user", "--map-root-user", "--mount", "--fork", sys.executable,
                 str(Path(__file__).resolve()), "--kernel-worker", directory],
                capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(list(Path(directory, "mnt/usb").iterdir()), [])


if __name__ == "__main__":
    if sys.argv[1:2] == ["--kernel-worker"]:
        kernel_worker(sys.argv[2])
    else:
        unittest.main()
