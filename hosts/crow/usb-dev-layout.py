"""Maintain normal /dev names for USB-only nodes in the read-only host mirror.

Runs as remapped guest root, never as host root. No device creation privileges
are required: aliases follow the existing USB nodes, including hotplug changes.
"""

import json
import os
from pathlib import Path
import stat
import time

SOURCE = Path("/run/crow-ai-usb-devices")
STATE = Path("/run/crow-ai-usb-layout/links.json")


def valid_relative(name):
    return isinstance(name, str) and name and not name.startswith("/") and all(
        part not in {"", ".", ".."} for part in name.split("/")
    )


def parent_directory(dev, relative):
    parent = dev
    for part in Path(relative).parts[:-1]:
        parent = parent / part
        try:
            parent.mkdir(mode=0o755)
        except FileExistsError:
            pass
        if parent.is_symlink() or not parent.is_dir():
            return False
    return True


def owned_link(path, source):
    return path.is_symlink() and os.readlink(path) == str(source)


def sync(source=SOURCE, dev=Path("/dev"), state=STATE):
    previous = json.loads(state.read_text()) if state.exists() else []
    desired = set()
    for directory, _, names in os.walk(source, followlinks=False):
        for name in names:
            node = Path(directory) / name
            relative = str(node.relative_to(source))
            # Raw USB has a direct directory bind at /dev/bus/usb.
            if relative.startswith("bus/usb/"):
                continue
            try:
                mode = node.lstat().st_mode
            except FileNotFoundError:
                continue
            if stat.S_ISCHR(mode) or stat.S_ISBLK(mode):
                desired.add(relative)
    for relative in set(previous) - desired:
        if valid_relative(relative) and parent_directory(dev, relative):
            path = dev / relative
            if owned_link(path, source / relative):
                path.unlink()
    managed = []
    for relative in sorted(desired):
        if not parent_directory(dev, relative):
            continue
        path = dev / relative
        if owned_link(path, source / relative):
            managed.append(relative)
        elif not os.path.lexists(path):
            path.symlink_to(source / relative)
            managed.append(relative)
        # Never replace a pre-existing device, file, or foreign symlink.
    state.parent.mkdir(parents=True, exist_ok=True)
    temporary = state.with_suffix(".tmp")
    temporary.write_text(json.dumps(managed))
    temporary.replace(state)


if __name__ == "__main__":
    import sys
    while True:
        sync()
        if "--once" in sys.argv[1:]:
            break
        time.sleep(0.5)
