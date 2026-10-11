#!/usr/bin/env python3
"""Prepare a disposable path flake with SOPS hardware inventory outside Git."""
import argparse
import base64
import hashlib
import re
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

INVENTORY = "hardware-identities.json"
MANIFEST = ".hardware-source-files.json"


FIXTURE_MARKER = ".hardware-fixture"


def validate_inventory(inventory, schema, path=()):
    if isinstance(schema, dict):
        if not isinstance(inventory, dict) or inventory.keys() != schema.keys():
            raise ValueError("Hardware fields do not match schema at " + ".".join(path))
        for key, kind in schema.items():
            validate_inventory(inventory[key], kind, path + (key,))
    else:
        patterns = {
            "uuid": r"[0-9a-fA-F-]+",
            "host-id": r"[0-9a-fA-F]{8}",
            "volume-key-id": r"[0-9a-fA-F]{64}",
            "mac-address": r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}",
            "duid": r"(?:[0-9a-fA-F]{2}:)*[0-9a-fA-F]{2}",
            "device-id": r"[a-zA-Z0-9_.:+-]+",
            "usb-hash": r"[A-Za-z0-9+/]{43}=",
            "string": r"[^\n\r\0]+",
        }
        valid = (type(inventory) is int and 0 <= inventory <= 0xffffffff) if schema == "integer" else (
            inventory is None and schema == "volume-key-id" or
            isinstance(inventory, str) and re.fullmatch(patterns[schema], inventory) is not None)
        if not valid:
            raise ValueError("Invalid hardware value at " + ".".join(path))
    return inventory


def fixture_inventory(schema, path=()):
    """Deterministic synthetic values; never derive fixtures from production data."""
    if isinstance(schema, dict):
        return {k: fixture_inventory(v, path + (k,)) for k, v in schema.items()}
    digest = hashlib.sha256("fixture/".encode() + "/".join(path).encode()).hexdigest()
    return {
        "integer": int(digest[:8], 16),
        "uuid": f"{digest[:8]}-{digest[8:12]}-4000-8000-{digest[12:24]}",
        "host-id": digest[:8], "volume-key-id": digest,
        "mac-address": "02:" + ":".join(digest[i:i+2] for i in range(0, 10, 2)),
        "duid": "00:04:" + ":".join(digest[i:i+2] for i in range(0, 32, 2)),
        "device-id": "synthetic-ci-disk-" + digest[:8],
        "usb-hash": base64.b64encode(bytes.fromhex(digest)).decode(),
        "string": "synthetic-ci-" + digest[:8],
    }[schema]


def read_inventory(repo, inventory_file=None, fixtures=False):
    if (repo / MANIFEST).exists() and (repo / ".git").exists():
        raise ValueError("Prepared source manifest must not be placed in a Git checkout")
    schema = json.loads((repo / "lib/hardware-identities-schema.json").read_text())
    if fixtures:
        if inventory_file:
            raise ValueError("Fixtures cannot use production inventory")
        inventory = fixture_inventory(schema)
    elif inventory_file:
        inventory = json.loads(Path(inventory_file).read_text())
    elif (repo / MANIFEST).is_file():
        inventory = json.loads((repo / INVENTORY).read_text())
    else:
        inventory = {}
        for host in schema:
            result = subprocess.run(["sops", "--decrypt", str(repo / "secrets/hardware" / (host + ".json"))],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode:
                raise RuntimeError(f"Cannot decrypt hardware settings for {host}; configure a SOPS recipient key (output withheld)")
            try:
                inventory[host] = json.loads(result.stdout)
            except ValueError:
                raise RuntimeError(f"Invalid decrypted JSON for {host} (output withheld)") from None
    return validate_inventory(inventory, schema)


def verify_fixtures(repo):
    """Require exact synthetic data, not merely an easily copied marker."""
    repo = Path(repo)
    if not (repo / FIXTURE_MARKER).is_file():
        raise ValueError("Public publishing requires a fixture source")
    actual = json.loads((repo / INVENTORY).read_text())
    expected = fixture_inventory(json.loads((repo / "lib/hardware-identities-schema.json").read_text()))
    if actual != expected:
        raise ValueError("Public publishing refused: inventory differs from synthetic fixtures")


def source_files(repo):
    if (repo / MANIFEST).is_file():
        names = json.loads((repo / MANIFEST).read_text())
    else:
        root = subprocess.run(["git", "-C", str(repo), "rev-parse", "--show-toplevel"],
                              capture_output=True, text=True, check=True).stdout.strip()
        if Path(root).resolve() != repo.resolve():
            raise ValueError("Source must be the repository root or a prepared snapshot")
        names = subprocess.check_output(["git", "-C", str(repo), "ls-files", "-z", "--cached", "--others", "--exclude-standard"]).decode().split('\0')
    result = []
    for name in sorted(set(names)):
        if not name:
            continue
        path = Path(name)
        if path.is_absolute() or '..' in path.parts or path.parts[0] in ('.git', 'keys'):
            raise ValueError("Unsafe source path")
        if name in (INVENTORY, MANIFEST, FIXTURE_MARKER):
            raise ValueError("Decrypted inventory must never be tracked or listed in the source manifest")
        source = repo / path
        if source.is_symlink() and (not source.resolve().is_relative_to(repo) or str(source.resolve().relative_to(repo)) not in names):
            raise ValueError(f"Source symlink requires review: {name}")
        if any((repo / p).is_symlink() for p in source.relative_to(repo).parents if p != Path('.')):
            raise ValueError(f"Source directory symlink requires review: {name}")
        if not source.exists():
            continue  # tracked deletion
        if not source.is_file():
            raise ValueError(f"Not a regular source file: {name}")
        result.append(name)
    return result


def prepare(repo, destination, inventory_file=None, fixtures=False):
    repo = Path(repo).resolve()
    destination = Path(destination).absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError("Destination must not exist")
    if destination.resolve().is_relative_to(repo):
        raise ValueError("Prepared source must be outside the repository")
    inventory = read_inventory(repo, inventory_file, fixtures)
    files = source_files(repo)
    destination.mkdir(mode=0o700)
    try:
        for name in files:
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(repo / name, target, follow_symlinks=False)
        if fixtures or (repo / FIXTURE_MARKER).exists():
            (destination / FIXTURE_MARKER).write_text("Synthetic CI configuration; do not install.\n")
        for name, data in ((INVENTORY, inventory), (MANIFEST, files)):
            target = destination / name
            target.write_text(json.dumps(data, indent=2) + '\n')
            target.chmod(0o600)
    except BaseException:
        shutil.rmtree(destination)
        raise
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    parser.add_argument('--inventory', type=Path, help='Use an existing local plaintext inventory instead of SOPS')
    parser.add_argument('--fixtures', action='store_true', help='Use synthetic CI identities; never install these builds')
    commands = parser.add_subparsers(dest='action', required=True)
    commands.add_parser('verify-fixtures')
    stage = commands.add_parser('prepare')
    stage.add_argument('destination', type=Path)
    run = commands.add_parser('run')
    run.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.action == 'verify-fixtures':
            verify_fixtures(args.repo)
            return 0
        if args.action == 'prepare':
            print(prepare(args.repo, args.destination, args.inventory, args.fixtures))
            return 0
        command = args.command
        if command[:1] == ['--']:
            command = command[1:]
        if not command:
            raise ValueError('run requires a command after --')
        with tempfile.TemporaryDirectory(prefix='nixos-hardware-') as temporary:
            source = prepare(args.repo, Path(temporary) / 'source', args.inventory, args.fixtures)
            return subprocess.run(command, cwd=source).returncode
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Hardware provisioning stopped: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
