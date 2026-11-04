"""Check Codex filesystem headroom without modifying state or deleting files."""
import argparse
import os
import sys
import time


GIB = 1024 ** 3


def available_bytes(path):
    usage = os.statvfs(path)
    return usage.f_bavail * usage.f_frsize


def check(path, minimum, wait=False, interval=30):
    waiting = False
    next_warning = 0
    while True:
        free = available_bytes(path)
        if free >= minimum:
            if waiting:
                print(f"Codex storage recovered: {free / GIB:.1f} GiB available at {path}; continuing startup.", flush=True)
            elif not wait:
                print(f"Codex storage: {free / GIB:.1f} GiB available at {path}; minimum {minimum / GIB:g} GiB.", flush=True)
            return 0
        now = time.monotonic()
        if not waiting or now >= next_warning:
            action = "Waiting before starting Codex" if wait else "Codex storage check failed"
            print(f"{action}: only {free / GIB:.2f} GiB available at {path}; need {minimum / GIB:g} GiB. "
                  "Free space on the backing filesystem; this check does not delete caches, backups, or databases.",
                  file=sys.stderr, flush=True)
            next_warning = now + 300
        if not wait:
            return 1
        waiting = True
        time.sleep(interval)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path")
    parser.add_argument("--min-free-gib", type=float, default=40)
    parser.add_argument("--wait", action="store_true", help="Wait for headroom instead of failing the check")
    args = parser.parse_args(argv)
    if args.min_free_gib <= 0:
        parser.error("--min-free-gib must be positive")
    try:
        return check(args.path, args.min_free_gib * GIB, args.wait)
    except OSError as error:
        print(f"Cannot check Codex storage at {args.path}: {error}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
