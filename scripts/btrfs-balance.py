"""Reclaim Btrfs block groups once per mounted, writable filesystem."""
import json
import subprocess
import sys


def log(message):
    print(message, flush=True)


def balance(mountpoints):
    seen = set()
    failed = False
    for mountpoint in mountpoints:
        try:
            found = subprocess.run(
                ["findmnt", "--json", "--mountpoint", mountpoint,
                 "--output", "FSTYPE,UUID,OPTIONS"],
                capture_output=True, text=True,
            )
            if found.returncode == 1:
                log(f"Skipping unmounted filesystem {mountpoint!r}")
                continue
            found.check_returncode()
            mounts = json.loads(found.stdout).get("filesystems", [])
            if len(mounts) != 1:
                raise ValueError("expected exactly one mount")
            mounted = mounts[0]
            if mounted["fstype"] != "btrfs" or "ro" in mounted["options"].split(","):
                log(f"Skipping non-Btrfs or read-only mount {mountpoint!r}")
                continue
            identity = mounted.get("uuid")
            if not identity:
                raise ValueError("cannot identify Btrfs filesystem UUID")
            if identity in seen:
                continue
            seen.add(identity)
            status = subprocess.run(["btrfs", "balance", "status", mountpoint])
            if status.returncode == 1:
                log(f"Skipping existing balance on {mountpoint!r}")
                continue
            status.check_returncode()
            log(f"Reclaiming empty block groups on {mountpoint!r}")
            subprocess.run(
                ["btrfs", "balance", "start", "-dusage=0", "-musage=0", mountpoint],
                check=True,
            )
            log(f"Balancing at most eight data groups up to 50% used on {mountpoint!r}")
            subprocess.run(
                ["btrfs", "balance", "start", "-dusage=50,limit=8", mountpoint],
                check=True,
            )
        except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
            log(f"Btrfs maintenance failed on {mountpoint!r}: {error}")
            failed = True
    return int(failed)


if __name__ == "__main__":
    sys.exit(balance(sys.argv[1:]))
