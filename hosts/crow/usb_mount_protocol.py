"""Small, deliberately limited protocol shared by the USB mount wrappers/broker."""

import re

SOCKET = "/run/crow-ai-usb-mount/control.sock"
MAX_MESSAGE = 4096
FILESYSTEMS = {"ext2", "ext3", "ext4", "btrfs", "xfs", "vfat", "exfat", "ntfs3", "iso9660", "udf"}
OPTIONS = {"ro", "rw", "noatime", "relatime", "nosuid", "nodev", "noexec"}


class Rejected(Exception):
    pass


def device_name(source):
    if not isinstance(source, str) or not re.fullmatch(r"/dev/[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", source):
        raise Rejected("Use the normal block device path, for example /dev/sdb1.")
    return source.rsplit("/", 1)[1]


def target_path(target):
    if not isinstance(target, str) or len(target) > 512:
        raise Rejected("Use an empty directory under /mnt or /media.")
    parts = target.split("/")
    if len(parts) < 3 or parts[0] or parts[1] not in {"mnt", "media"} or any(
        not part or part in {".", ".."} or not re.fullmatch(r"[A-Za-z0-9_.-]+", part)
        for part in parts[2:]
    ):
        raise Rejected("Use a canonical path under /mnt or /media, without symlinks.")
    return target


def validate_request(request):
    if not isinstance(request, dict):
        raise Rejected("Expected a USB mount request.")
    if request.get("op") == "mount":
        if set(request) != {"op", "source", "target", "fstype", "options"}:
            raise Rejected("Invalid mount request fields.")
        device_name(request["source"])
        target_path(request["target"])
        if request["fstype"] is not None and (
            not isinstance(request["fstype"], str) or request["fstype"] not in FILESYSTEMS
        ):
            raise Rejected("Unsupported USB filesystem type.")
        options = request["options"]
        if not isinstance(options, list) or len(options) > 16 or any(
            not isinstance(option, str) or option not in OPTIONS for option in options
        ):
            raise Rejected("Allowed options: ro, rw, noatime, relatime, nosuid, nodev, noexec.")
        if {"ro", "rw"} <= set(options) or {"noatime", "relatime"} <= set(options):
            raise Rejected("Conflicting mount options.")
    elif request.get("op") == "umount":
        if set(request) != {"op", "target"}:
            raise Rejected("Invalid unmount request fields.")
        target = request["target"]
        if isinstance(target, str) and target.startswith("/dev/"):
            device_name(target)
        else:
            target_path(target)
    else:
        raise Rejected("Only USB mount and umount requests are supported.")
    return request
