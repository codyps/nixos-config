#!/usr/bin/env python3
"""Print systemd's public volume-key ID without activating or modifying LUKS."""

import argparse
import ctypes as C
import ctypes.util
import getpass
import hashlib
import hmac
import os
import pathlib
import re
import resource
import sys


def main():
    parser = argparse.ArgumentParser(prog="luks-volume-key-id", description=__doc__)
    parser.add_argument("--device", required=True, help="LUKS1/LUKS2 device or image")
    parser.add_argument("--name", required=True, help="target mapper name from crypttab (part of the ID)")
    parser.add_argument("--key-file", help="existing LUKS passphrase file for unattended use")
    parser.add_argument("--library", help="libcryptsetup shared library path")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.name):
        parser.error("--name must contain only letters, digits, underscores, dots, or hyphens")
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    library = args.library or ctypes.util.find_library("cryptsetup")
    if not library:
        raise ValueError("libcryptsetup is required")
    lib = C.CDLL(library)

    def bind(name, result, *arguments):
        function = getattr(lib, name)
        function.restype = result
        function.argtypes = arguments
        return function

    init = bind("crypt_init", C.c_int, C.POINTER(C.c_void_p), C.c_char_p)
    load = bind("crypt_load", C.c_int, C.c_void_p, C.c_char_p, C.c_void_p)
    get_type = bind("crypt_get_type", C.c_char_p, C.c_void_p)
    uuid = bind("crypt_get_uuid", C.c_char_p, C.c_void_p)
    size = bind("crypt_get_volume_key_size", C.c_int, C.c_void_p)
    get_key = bind("crypt_volume_key_get", C.c_int, C.c_void_p, C.c_int,
                   C.c_void_p, C.POINTER(C.c_size_t), C.c_char_p, C.c_size_t)
    free = bind("crypt_free", None, C.c_void_p)

    def check(result):
        if result < 0:
            raise OSError(-result, os.strerror(-result))
        return result

    device = C.c_void_p()
    key = None
    try:
        check(init(C.byref(device), os.fsencode(args.device)))
        check(load(device, None, None))
        if get_type(device) not in (b"LUKS1", b"LUKS2"):
            raise ValueError("Device must contain a LUKS1 or LUKS2 header")
        volume_uuid = uuid(device)
        key_size = check(size(device))
        if not volume_uuid or not key_size:
            raise ValueError("Missing LUKS UUID or volume key")
        password = (pathlib.Path(args.key_file).read_bytes() if args.key_file
                    else getpass.getpass("LUKS passphrase: ").encode())
        key = C.create_string_buffer(key_size)
        length = C.c_size_t(key_size)
        check(get_key(device, -1, key, C.byref(length), password, len(password)))
        # Matches systemd cryptsetup_get_volume_key_id(); only the public HMAC
        # leaves this process. No mapping is opened and no key file is written.
        prefix = b"cryptsetup:" + args.name.encode() + b":" + volume_uuid
        print(hmac.new(key.raw[:length.value], prefix, hashlib.sha256).hexdigest())
    finally:
        if key is not None:
            C.memset(key, 0, C.sizeof(key))
        if device:
            free(device)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, EOFError) as error:
        print(f"luks-volume-key-id: {error}", file=sys.stderr)
        sys.exit(1)
