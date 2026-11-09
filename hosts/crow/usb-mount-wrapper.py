"""Upstream-compatible mount/umount entry points; privilege lives in the broker."""

import argparse
import json
import os
import socket
import stat
import sys

from usb_mount_protocol import MAX_MESSAGE, SOCKET, Rejected, device_name, validate_request


def block_device_argument(command, argument):
    try:
        device_name(argument)
    except Rejected:
        return False
    # Unmount-by-device still works after unplugging. The host broker always
    # validates actual USB ancestry; normal /dev names do not confer authority.
    if command == "umount":
        return True
    try:
        return stat.S_ISBLK(os.stat(argument).st_mode)
    except OSError:
        return False


def request_for(command, arguments):
    usb = any(block_device_argument(command, argument) for argument in arguments)
    managed_target = command == "umount" and any(
        argument.startswith(("/mnt/", "/media/")) for argument in arguments
    )
    if not usb and not managed_target:
        return None
    parser = argparse.ArgumentParser(prog=command, description="Crow USB mount helper; see /etc/crow-ai-usb-mounts.md")
    parser.add_argument("-v", "--verbose", action="store_true")
    if command == "mount":
        parser.add_argument("-t", "--types", dest="fstype")
        parser.add_argument("-o", "--options", action="append", default=[])
        mode = parser.add_mutually_exclusive_group()
        mode.add_argument("-r", "--read-only", action="store_true")
        mode.add_argument("-w", "--rw", action="store_true")
        parser.add_argument("source")
        parser.add_argument("target")
        args = parser.parse_args(arguments)
        options = [option for group in args.options for option in group.split(",")]
        if args.read_only:
            options.append("ro")
        if args.rw:
            options.append("rw")
        request = dict(op=command, source=args.source, target=args.target, fstype=args.fstype, options=options)
    else:
        parser.add_argument("target")
        args = parser.parse_args(arguments)
        request = dict(op=command, target=args.target)
    return validate_request(request)


def exchange(request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(120)
        connection.connect(SOCKET)
        connection.sendall(json.dumps(request).encode() + b"\n")
        data = b""
        while b"\n" not in data:
            chunk = connection.recv(MAX_MESSAGE + 1 - len(data))
            if not chunk or len(data) + len(chunk) > MAX_MESSAGE:
                raise Rejected("Invalid response from the USB mount service.")
            data += chunk
        return json.loads(data)


def main():
    command, real_command, *arguments = sys.argv[1:]
    try:
        request = request_for(command, arguments)
        if request is None:
            os.execv(real_command, [command, *arguments])
        if os.geteuid() != 0:
            raise Rejected("Use sudo for USB filesystem mounts and unmounts.")
        response = exchange(request)
        if response.get("status") == "not-managed" and command == "umount":
            os.execv(real_command, [command, *arguments])
        if response.get("status") != "ok":
            raise Rejected(response.get("error", "USB mount request failed."))
    except (Rejected, OSError, ValueError) as error:
        print(f"{command}: {error}\nUSB help: sys usb-mount-help", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
