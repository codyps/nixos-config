"""Dispatch repository administration commands installed as sys-* executables."""

import os
from pathlib import Path
import sys


def commands():
    found = {}
    for directory in os.get_exec_path():
        if not directory:
            continue
        try:
            entries = sorted(Path(directory).glob("sys-*"))
            for entry in entries:
                if entry.is_file() and os.access(entry, os.X_OK):
                    found.setdefault(entry.name[4:], str(entry.absolute()))
        except OSError:
            continue
    return found


def main():
    available = commands()
    args = sys.argv[1:]
    if not args or args[0] in ("help", "--help", "-h", "--list"):
        print("Usage: sys COMMAND [ARGUMENT ...]\n\nAvailable commands:")
        for name in sorted(available):
            print(f"  {name}")
        print("\nUse sys COMMAND --help where the command supports it.")
        return 0
    command = available.get(args[0])
    if command is None:
        print(f"sys: unknown command {args[0]!r}; run 'sys help'", file=sys.stderr)
        return 2
    os.execv(command, [command, *args[1:]])


if __name__ == "__main__":
    sys.exit(main())
