#!/usr/bin/env python3
"""Prepare a disposable path flake with SOPS hardware inventory outside Git."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

INVENTORY = "hardware-identities.json"
MANIFEST = ".hardware-source-files.json"


def validate_inventory(inventory, schema):
    if not isinstance(inventory, dict) or inventory.keys() != schema.keys():
        raise ValueError("Hardware inventory hosts do not match the schema")
    for host, fields in schema.items():
        if not isinstance(inventory[host], dict) or inventory[host].keys() != fields.keys():
            raise ValueError(f"Hardware inventory fields do not match schema for {host}")
        for key, kind in fields.items():
            value = inventory[host][key]
            if kind == "integer":
                valid = type(value) is int and 0 <= value <= 0xffffffff
            else:
                valid = isinstance(value, str) and bool(value) and not any(c in value for c in '\n\r\0')
                # Only the explicit fresh-install volume pin may be absent.
                valid |= key == "rootVolumeKeyId" and value is None
            if not valid:
                raise ValueError(f"Invalid hardware inventory value for {host}.{key}")
    return inventory


def read_inventory(repo, inventory_file=None):
    if (repo / MANIFEST).exists() and (repo / ".git").exists():
        raise ValueError("Prepared source manifest must not be placed in a Git checkout")
    schema = json.loads((repo / "lib/hardware-identities-schema.json").read_text())
    if inventory_file:
        inventory = json.loads(Path(inventory_file).read_text())
    elif (repo / MANIFEST).is_file():
        inventory = json.loads((repo / INVENTORY).read_text())
    else:
        result = subprocess.run(["sops", "--decrypt", str(repo / "secrets/hardware-identities.json")],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            raise RuntimeError("Cannot decrypt hardware inventory; configure a SOPS recipient key (output withheld)")
        inventory = json.loads(result.stdout)
    return validate_inventory(inventory, schema)


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
        if name in (INVENTORY, MANIFEST):
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


def prepare(repo, destination, inventory_file=None):
    repo = Path(repo).resolve()
    destination = Path(destination).absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError("Destination must not exist")
    if destination.resolve().is_relative_to(repo):
        raise ValueError("Prepared source must be outside the repository")
    inventory = read_inventory(repo, inventory_file)
    files = source_files(repo)
    destination.mkdir(mode=0o700)
    try:
        for name in files:
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(repo / name, target, follow_symlinks=False)
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
    commands = parser.add_subparsers(dest='action', required=True)
    stage = commands.add_parser('prepare')
    stage.add_argument('destination', type=Path)
    run = commands.add_parser('run')
    run.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.action == 'prepare':
            print(prepare(args.repo, args.destination, args.inventory))
            return 0
        command = args.command
        if command[:1] == ['--']:
            command = command[1:]
        if not command:
            raise ValueError('run requires a command after --')
        with tempfile.TemporaryDirectory(prefix='nixos-hardware-') as temporary:
            source = prepare(args.repo, Path(temporary) / 'source', args.inventory)
            return subprocess.run(command, cwd=source).returncode
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Hardware provisioning stopped: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
