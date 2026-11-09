"""Socket-activated USB mount broker for Crow's remapped nspawn container.

All paths/namespace descriptors originate on the host. No guest executable is
ever run with host privileges. Mounts are detached until moved into the guest.
"""

from contextlib import ExitStack
import ctypes
import json
import os
from pathlib import Path
import re
import socket
import stat
import struct
import subprocess
import sys
import uuid

from usb_mount_protocol import FILESYSTEMS, MAX_MESSAGE, Rejected, device_name, target_path, validate_request

LIBC = ctypes.CDLL(None, use_errno=True)
UID_BASE = 1048576
UID_COUNT = 1048576
STATE = Path("/run/crow-ai-usb-mount-state/state.json")
O_PATH = os.O_PATH | os.O_CLOEXEC
AT_EMPTY_PATH = 0x1000
CLONE_NEWNS = 0x20000


class OpenHow(ctypes.Structure):
    _fields_ = [("flags", ctypes.c_uint64), ("mode", ctypes.c_uint64), ("resolve", ctypes.c_uint64)]


class MountAttr(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint64) for name in ("attr_set", "attr_clr", "propagation", "userns_fd")]


def checked(value):
    if value < 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))
    return value


def open_beneath(rootfd, path):
    # Linux openat2: RESOLVE_IN_ROOT | RESOLVE_NO_SYMLINKS. Absolute paths,
    # symlink races, magic links, and '..' cannot escape the pinned guest root.
    how = OpenHow(O_PATH | os.O_DIRECTORY, 0, 0x10 | 0x04)
    return checked(LIBC.syscall(437, rootfd, os.fsencode(path), ctypes.byref(how), ctypes.sizeof(how)))


def mount_id(fd):
    data = Path(f"/proc/self/fdinfo/{fd}").read_text()
    return int(re.search(r"^mnt_id:\s+(\d+)$", data, re.MULTILINE)[1])


def detached_mount(fstype, source=None, parameters=(), readonly=False, noatime=False, userns=None):
    """Use the kernel mount API, not mount helpers, fstab, or a shell."""
    with ExitStack() as stack:
        fsfd = checked(LIBC.fsopen(os.fsencode(fstype), 1))
        stack.callback(os.close, fsfd)
        if source is not None:
            parameters = [("source", source), *parameters]
        for key, value in parameters:
            checked(LIBC.fsconfig(fsfd, 1, os.fsencode(key), os.fsencode(str(value)), 0))
        if readonly:
            checked(LIBC.fsconfig(fsfd, 0, b"ro", None, 0))
        checked(LIBC.fsconfig(fsfd, 6, None, None, 0))  # FSCONFIG_CMD_CREATE
        attrs = 2 | 4 | 8  # NOSUID | NODEV | NOEXEC, always mandatory.
        if readonly:
            attrs |= 1
        if noatime:
            attrs |= 0x10
        fd = checked(LIBC.fsmount(fsfd, 1, attrs))
        try:
            if userns is not None:
                attr = MountAttr(0x100000, 0, 0, userns)  # MOUNT_ATTR_IDMAP
                checked(LIBC.mount_setattr(fd, b"", AT_EMPTY_PATH, ctypes.byref(attr), ctypes.sizeof(attr)))
            return fd
        except BaseException:
            os.close(fd)
            raise


def attach_mount(fd, targetfd):
    checked(LIBC.move_mount(fd, b"", targetfd, b"", 0x04 | 0x40))


def fork_job(action):
    # Only this short-lived child enters the guest mount namespace. It retains
    # host credentials but runs no guest code, resolves no arbitrary paths, and
    # never joins the guest user namespace.
    readfd, writefd = os.pipe2(os.O_CLOEXEC)
    pid = os.fork()
    if pid == 0:
        os.close(readfd)
        try:
            action()
            result = b""
        except OSError as error:
            result = f"{error.errno}: {os.strerror(error.errno)}".encode()
        except BaseException:
            result = b"Namespace operation failed"
        os.write(writefd, result)
        os._exit(bool(result))
    os.close(writefd)
    try:
        result = os.read(readfd, 1024)
    finally:
        os.close(readfd)
        _, status = os.waitpid(pid, 0)
    if status != 0:
        raise Rejected(result.decode() or "Namespace operation failed.")


class Guest(ExitStack):
    def __init__(self, peer_pid, peer_uid, machinectl):
        super().__init__()
        try:
            if peer_uid != UID_BASE:
                raise Rejected("Only sudo/root inside crow-ai may request USB mounts.")
            leader = int(subprocess.check_output(
                [machinectl, "show", "crow-ai", "--property=Leader", "--value"],
                timeout=5, text=True,
            ).strip())
            if leader <= 1:
                raise Rejected("crow-ai is not running.")
            procfd = self.keep(os.open(f"/proc/{leader}", O_PATH | os.O_DIRECTORY))
            self.procfd = procfd
            for name in ("uid_map", "gid_map"):
                fd = self.keep(os.open(name, os.O_RDONLY | os.O_CLOEXEC, dir_fd=procfd))
                if os.read(fd, 1024).split() != [b"0", str(UID_BASE).encode(), str(UID_COUNT).encode()]:
                    raise Rejected("crow-ai must use its configured remapped user namespace.")
            self.userns = self.keep(os.open("ns/user", os.O_RDONLY | os.O_CLOEXEC, dir_fd=procfd))
            self.mountns = self.keep(os.open("ns/mnt", os.O_RDONLY | os.O_CLOEXEC, dir_fd=procfd))
            self.root = self.keep(os.open("root", O_PATH | os.O_DIRECTORY, dir_fd=procfd))
            for name, fd in (("user", self.userns), ("mnt", self.mountns)):
                if os.stat(f"/proc/{peer_pid}/ns/{name}").st_ino != os.fstat(fd).st_ino:
                    raise Rejected("The requester must be in crow-ai's main user and mount namespaces.")
            self.identity = os.fstat(self.mountns).st_ino
        except BaseException:
            self.close()
            raise

    def keep(self, fd):
        self.callback(os.close, fd)
        return fd

    def target(self, target, empty=False):
        target_path(target)
        parent, name = target.rsplit("/", 1)
        parentfd = open_beneath(self.root, parent)
        try:
            fd = open_beneath(parentfd, name)
            try:
                if empty:
                    directory = os.open(".", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC, dir_fd=fd)
                    try:
                        if mount_id(fd) != mount_id(parentfd) or os.listdir(directory):
                            raise Rejected("The USB mount target must be an empty, unmounted directory.")
                    finally:
                        os.close(directory)
                return parentfd, fd, name
            except BaseException:
                os.close(fd)
                raise
        except BaseException:
            os.close(parentfd)
            raise

    def attach(self, fd, targetfd):
        def action():
            os.setns(self.mountns, CLONE_NEWNS)
            attach_mount(fd, targetfd)
        fork_job(action)

    def mount_ids(self):
        fd = os.open("mountinfo", os.O_RDONLY | os.O_CLOEXEC, dir_fd=self.procfd)
        with os.fdopen(fd) as source:
            return {int(line.split()[0]) for line in source}

    def unmount(self, parentfd, name):
        def action():
            os.setns(self.mountns, CLONE_NEWNS)
            # Pin the parent before changing namespaces. chroot/fchdir keep
            # umount's path lookup away from the host root and guest symlinks.
            os.fchdir(parentfd)
            os.chroot(".")
            os.chdir("/")
            checked(LIBC.umount2(os.fsencode(name), 8))  # UMOUNT_NOFOLLOW
        fork_job(action)


def usb_disk(sysnode):
    """Validate USB bus ancestry, not a guest-supplied node or udev property."""
    if not any((ancestor / "subsystem").resolve() == Path("/sys/bus/usb") for ancestor in sysnode.parents):
        raise Rejected("The block device is not attached through USB.")
    return sysnode.parent if (sysnode / "partition").exists() else sysnode


def check_disk_unused(disk, mountinfo, swaps):
    family = [disk, *(child for child in disk.iterdir() if (child / "partition").exists())]
    devices = {(node / "dev").read_text().strip() for node in family}
    if any(list((node / "holders").iterdir()) for node in family):
        raise Rejected("The USB disk has active device-mapper/RAID holders.")
    if devices & {line.split()[2] for line in mountinfo.splitlines()}:
        raise Rejected("The USB disk or one of its partitions is mounted on the host.")
    # Btrfs reports an anonymous st_dev in mountinfo. Its sysfs device list
    # includes every member, including members other than the mount source.
    if any(node.read_text().strip() in devices for node in Path("/sys/fs/btrfs").glob("*/devices/*/dev")):
        raise Rejected("The USB disk is part of a mounted host Btrfs filesystem.")
    # Likewise, a loop device can claim a raw block device without a sysfs
    # holder entry. Only inspect host-owned sysfs paths, never guest paths.
    for backing in Path("/sys/block").glob("loop*/loop/backing_file"):
        name = backing.read_text().strip()
        if name.startswith("/dev/"):
            backing_stat = os.stat(name)
            if stat.S_ISBLK(backing_stat.st_mode) and f"{os.major(backing_stat.st_rdev)}:{os.minor(backing_stat.st_rdev)}" in devices:
                raise Rejected("The USB disk is used by a host loop device.")
    for line in swaps.splitlines()[1:]:
        swap = os.stat(line.split()[0])
        dev = swap.st_rdev if stat.S_ISBLK(swap.st_mode) else swap.st_dev
        if f"{os.major(dev)}:{os.minor(dev)}" in devices:
            raise Rejected("The USB disk is in use for swap.")


def check_filesystem(fd, fstype, btrfs_registry=Path("/sys/fs/btrfs")):
    # Do not let ordinary multi-device filesystem features expand the selected
    # USB device into an external journal, Btrfs member, or a registered host FS.
    # Media still must be trusted: a shared-kernel parser is not an image sandbox,
    # and concurrent raw writers must not modify metadata during a mount.
    if fstype in {"ext2", "ext3", "ext4"}:
        data = os.pread(fd, 1024, 1024)
        if len(data) != 1024 or data[0x38:0x3a] != b"\x53\xef":
            raise Rejected("Invalid ext filesystem superblock.")
        compat, incompat = struct.unpack_from("<II", data, 0x5c)
        journal_inode, journal_device = struct.unpack_from("<II", data, 0xe0)
        if journal_device or incompat & 0x08 or (compat & 0x04 and not journal_inode):
            raise Rejected("External journal devices are not allowed.")
    elif fstype == "btrfs":
        data = os.pread(fd, 4096, 65536)
        if len(data) != 4096 or data[0x40:0x48] != b"_BHRfS_M":
            raise Rejected("Invalid Btrfs superblock.")
        devices = struct.unpack_from("<Q", data, 0x88)[0]
        flags = struct.unpack_from("<Q", data, 0x38)[0]
        incompatible = struct.unpack_from("<Q", data, 0xbc)[0]
        if devices != 1 or flags & (1 << 32) or incompatible & (1 << 10):
            raise Rejected("Only single-device, non-seeding Btrfs without metadata-UUID remapping is allowed.")
        if (btrfs_registry / str(uuid.UUID(bytes=data[0x20:0x30]))).exists():
            raise Rejected("The Btrfs filesystem is already registered on the host.")


class Device(ExitStack):
    def __init__(self, source, blkid):
        super().__init__()
        try:
            name = device_name(source)
            self.fd = os.open(f"/dev/{name}", os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC)
            self.callback(os.close, self.fd)
            device = os.fstat(self.fd)
            if not stat.S_ISBLK(device.st_mode):
                raise Rejected("The requested USB node is not a block device.")
            self.number = f"{os.major(device.st_rdev)}:{os.minor(device.st_rdev)}"
            self.sysnode = Path(f"/sys/dev/block/{self.number}").resolve(strict=True)
            self.disk = usb_disk(self.sysnode)
            self.disk_number = (self.disk / "dev").read_text().strip()
            self.check_unused()
            result = subprocess.run(
                [blkid, "-p", "-s", "TYPE", "-o", "value", f"/proc/self/fd/{self.fd}"],
                pass_fds=(self.fd,), capture_output=True, text=True, timeout=10,
            )
            detected = result.stdout.strip()
            self.fstype = "ntfs3" if detected == "ntfs" else detected
            if result.returncode != 0 or self.fstype not in FILESYSTEMS:
                raise Rejected("Unsupported or ambiguous USB filesystem; LUKS, RAID and LVM are not mounted.")
        except BaseException:
            self.close()
            raise

    def check_unused(self):
        # /proc/1 is the host's PID 1 even when the service has its own mount
        # namespace. A pinned block fd and a second check narrow hotplug races.
        self.check_current()
        check_disk_unused(self.disk, Path("/proc/1/mountinfo").read_text(), Path("/proc/swaps").read_text())

    def check_current(self):
        if Path(f"/sys/dev/block/{self.number}").resolve(strict=True) != self.sysnode:
            raise Rejected("The USB device changed during the request.")
        usb_disk(self.sysnode)

    def mount(self, guest, request):
        if request["fstype"] not in (None, self.fstype):
            raise Rejected("The requested filesystem type does not match the device.")
        options = request["options"]
        parameters = []
        if self.fstype in {"vfat", "exfat", "ntfs3", "iso9660", "udf"}:
            parameters = [("uid", UID_BASE + 1001), ("gid", UID_BASE + 993)]
            if self.fstype in {"vfat", "exfat", "ntfs3", "udf"}:
                parameters.append(("umask", "0077"))
            userns = None
        else:
            userns = guest.userns
        self.check_unused()
        check_filesystem(self.fd, self.fstype)
        fd = detached_mount(
            self.fstype, f"/proc/self/fd/{self.fd}", parameters,
            readonly="ro" in options or self.fstype == "iso9660",
            noatime="noatime" in options, userns=userns,
        )
        try:
            # A detached Btrfs mount itself appears in host Btrfs sysfs. The
            # host-use check precedes creation; after creation recheck hotplug.
            self.check_current()
            return fd
        except BaseException:
            os.close(fd)
            raise


class Broker:
    def __init__(self, machinectl, blkid, state=STATE):
        self.machinectl, self.blkid, self.state = machinectl, blkid, state
        self.records = json.loads(state.read_text()) if state.exists() else []

    def save(self):
        temporary = self.state.with_suffix(".tmp")
        with open(temporary, "w", opener=lambda path, flags: os.open(path, flags, 0o600)) as output:
            json.dump(self.records, output)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, self.state)

    def prune(self, guest):
        mounted = guest.mount_ids()
        self.records = [record for record in self.records
                        if record["namespace"] == guest.identity and record["mount_id"] in mounted]
        self.save()

    def handle(self, request, peer_pid, peer_uid):
        validate_request(request)
        with Guest(peer_pid, peer_uid, self.machinectl) as guest:
            self.prune(guest)
            if request["op"] == "umount":
                return self.unmount(guest, request["target"])
            if len(self.records) >= 16:
                raise Rejected("At most 16 USB filesystems may be mounted at once.")
            target = request["target"]
            if any(target == record["target"] or target.startswith(record["target"] + "/") or
                   record["target"].startswith(target + "/") for record in self.records):
                raise Rejected("USB mount targets may not overlap.")
            with Device(request["source"], self.blkid) as device:
                if any(record["device"] in {device.number, device.disk_number} or
                       device.number == record["disk"] for record in self.records):
                    raise Rejected("The USB device is already mounted by this helper.")
                parentfd, targetfd, _ = guest.target(target, empty=True)
                try:
                    fd = device.mount(guest, request)
                    try:
                        record = dict(namespace=guest.identity, target=target, source=request["source"],
                                      device=device.number, disk=device.disk_number, mount_id=mount_id(fd))
                        # Persist before attachment: a service crash cannot leave
                        # a successful mount untracked. Unattached records prune.
                        self.records.append(record)
                        self.save()
                        guest.attach(fd, targetfd)
                    finally:
                        os.close(fd)
                finally:
                    os.close(targetfd)
                    os.close(parentfd)
            return {"status": "ok"}

    def unmount(self, guest, target):
        record = next((record for record in self.records if target in (record["target"], record["source"])), None)
        if record is None:
            return {"status": "not-managed"}
        parentfd, fd, name = guest.target(record["target"])
        try:
            try:
                if mount_id(fd) != record["mount_id"]:
                    raise Rejected("The USB mount changed; refusing to unmount a different filesystem.")
            finally:
                # An open fd on the mounted filesystem would make umount busy.
                os.close(fd)
            guest.unmount(parentfd, name)
        finally:
            os.close(parentfd)
        self.records.remove(record)
        self.save()
        return {"status": "ok"}


def receive(connection):
    data = b""
    while b"\n" not in data:
        chunk = connection.recv(MAX_MESSAGE + 1 - len(data))
        if not chunk or len(data) + len(chunk) > MAX_MESSAGE:
            raise Rejected("Invalid USB mount request length.")
        data += chunk
    return json.loads(data)


def serve(broker, listener):
    while True:
        connection, _ = listener.accept()
        with connection:
            connection.settimeout(5)
            try:
                pid, uid, _ = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                if uid != UID_BASE:
                    raise Rejected("Only sudo/root inside crow-ai may request USB mounts.")
                result = broker.handle(receive(connection), pid, uid)
            except (Rejected, OSError, ValueError, TypeError, subprocess.SubprocessError) as error:
                result = {"status": "error", "error": str(error)}
            try:
                connection.sendall(json.dumps(result).encode() + b"\n")
            except OSError:
                pass


if __name__ == "__main__":
    if os.environ.get("LISTEN_PID") != str(os.getpid()) or os.environ.get("LISTEN_FDS") != "1":
        sys.exit("Start crow-ai-usb-mount through its systemd socket.")
    serve(Broker(*sys.argv[1:]), socket.socket(fileno=3))
