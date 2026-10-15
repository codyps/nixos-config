#!/usr/bin/env python3
"""Read and validate machine-local hardware inventory from SOPS."""
import argparse
import base64
import hashlib
import re
import json
import os
from pathlib import Path
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


def select_host(inventory, schema, host):
    """Accept a host file or a legacy combined export; return only this host."""
    if host not in schema:
        raise ValueError('Unknown hardware host')
    if isinstance(inventory, dict) and host in inventory:
        if not inventory.keys() <= schema.keys():
            raise ValueError('Unknown hosts in hardware inventory')
        inventory = inventory[host]
    return validate_inventory({host: inventory}, {host: schema[host]})


def read_inventory(repo, inventory_file=None, fixtures=False, *, host=None,
                   schema_file=None, encrypted_file=None, sops_env=None):
    if (repo / MANIFEST).exists() and (repo / ".git").exists():
        raise ValueError("Prepared source manifest must not be placed in a Git checkout")
    schema = json.loads(Path(schema_file or repo / "lib/hardware-identities-schema.json").read_text())
    if not fixtures and host is None:
        raise ValueError('Select a host for production hardware inventory')
    if host is not None and host not in schema:
        raise ValueError('Unknown hardware host')
    if fixtures:
        if inventory_file:
            raise ValueError("Fixtures cannot use production inventory")
        inventory = fixture_inventory(schema)
    elif inventory_file:
        inventory = json.loads(Path(inventory_file).read_text())
    elif (repo / MANIFEST).is_file():
        inventory = json.loads((repo / INVENTORY).read_text())
    else:
        result = subprocess.run(["sops", "--decrypt", str(encrypted_file or repo / "secrets/hardware" / (host + ".json"))],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                **({'env': sops_env} if sops_env is not None else {}))
        if result.returncode:
            raise RuntimeError(f"Cannot decrypt hardware settings for {host}; configure a SOPS recipient key (output withheld)")
        try:
            inventory = json.loads(result.stdout)
        except ValueError:
            raise RuntimeError(f"Invalid decrypted JSON for {host} (output withheld)") from None
    return select_host(inventory, schema, host) if host is not None else validate_inventory(inventory, schema)


def verify_fixtures(repo, directory):
    """Verify the public template fixtures before a public upload."""
    directory = Path(directory)
    metadata = json.loads((directory / "metadata.json").read_text())
    if metadata != {"version": 1, "fixture": True}:
        raise ValueError("Public publishing requires a fixture input")
    expected = fixture_inventory(json.loads((Path(repo) / "lib/hardware-identities-schema.json").read_text()))
    if json.loads((directory / INVENTORY).read_text()) != expected:
        raise ValueError("Public publishing refused: inventory differs from synthetic fixtures")
    if {p.name for p in directory.iterdir()} != {INVENTORY, "metadata.json"}:
        raise ValueError("Fixture input contains unexpected files")


def provision(repo, destination, inventory_file=None, fixtures=False, *, host=None,
              schema_file=None, encrypted_file=None, sops_env=None):
    repo = Path(repo).resolve()
    destination = Path(destination).absolute()
    if destination.is_symlink() or destination.resolve().is_relative_to(repo):
        raise ValueError("Hardware input must be outside the repository and not a symlink")
    inventory = read_inventory(repo, inventory_file, fixtures, host=host, schema_file=schema_file,
                               encrypted_file=encrypted_file, sops_env=sops_env)
    metadata = {"version": 1, "fixture": fixtures}
    schema = json.loads(Path(schema_file or repo / "lib/hardware-identities-schema.json").read_text())
    synthetic = fixture_inventory(schema)
    if host is not None:
        synthetic = select_host(synthetic, schema, host)
    if not fixtures and inventory == synthetic:
        raise ValueError("Synthetic inventory cannot be provisioned as production")
    data = json.dumps(inventory, indent=2) + '\n'
    if destination.exists():
        if not destination.is_dir() or destination.stat().st_uid != os.getuid() or destination.stat().st_mode & 0o077:
            raise ValueError("Existing input must be an owned private directory")
        if {p.name for p in destination.iterdir()} != {INVENTORY, "metadata.json"} or any(p.is_symlink() for p in destination.iterdir()):
            raise ValueError("Existing input contains unexpected files or symlinks")
        if json.loads((destination / "metadata.json").read_text()) != metadata:
            raise ValueError("Cannot change an existing input's fixture mode")
        # Refresh only the inventory atomically. Its metadata is unchanged.
        with tempfile.NamedTemporaryFile(mode='w', dir=destination, delete=False) as output:
            pending = Path(output.name)
            output.write(data)
        try:
            os.replace(pending, destination / INVENTORY)
        finally:
            pending.unlink(missing_ok=True)
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='.hardware-input-', dir=destination.parent) as temporary:
            stage = Path(temporary) / 'input'
            stage.mkdir(mode=0o700)
            for name, value in ((INVENTORY, data), ("metadata.json", json.dumps(metadata) + '\n')):
                (stage / name).write_text(value)
                (stage / name).chmod(0o600)
            stage.rename(destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    parser.add_argument('--host', help='Export only this host; required outside fixture mode')
    parser.add_argument('--inventory', type=Path, help='Read existing local plaintext instead of decrypting SOPS')
    parser.add_argument('--fixtures', action='store_true', help='Generate synthetic data; never install these builds')
    parser.add_argument('--verify-fixtures', action='store_true', help='Verify an existing input for public publishing')
    parser.add_argument('destination', type=Path, help='Local input directory outside the checkout')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.verify_fixtures:
            if args.inventory or args.fixtures or args.host:
                raise ValueError('Verification cannot generate or replace input data')
            verify_fixtures(args.repo, args.destination)
        else:
            print(provision(args.repo, args.destination, args.inventory, args.fixtures, host=args.host))
        return 0
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Hardware provisioning stopped: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
