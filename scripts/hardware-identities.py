#!/usr/bin/env python3
"""Provision a local hardware flake input from SOPS, without wrapping Nix."""
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
import shutil
from urllib.parse import quote

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


def verify_fixtures(repo, directory):
    """Verify the resolved flake input before a public upload."""
    directory = Path(directory)
    metadata = json.loads((directory / "metadata.json").read_text())
    if metadata != {"version": 1, "fixture": True}:
        raise ValueError("Public publishing requires a fixture input")
    expected = fixture_inventory(json.loads((Path(repo) / "lib/hardware-identities-schema.json").read_text()))
    if json.loads((directory / INVENTORY).read_text()) != expected:
        raise ValueError("Public publishing refused: inventory differs from synthetic fixtures")
    if {p.name for p in directory.iterdir()} != {INVENTORY, "metadata.json"}:
        raise ValueError("Fixture input contains unexpected files")


def provision(repo, destination, inventory_file=None, fixtures=False):
    repo = Path(repo).resolve()
    destination = Path(destination).absolute()
    if destination.is_symlink() or destination.resolve().is_relative_to(repo):
        raise ValueError("Hardware input must be outside the repository and not a symlink")
    inventory = read_inventory(repo, inventory_file, fixtures)
    metadata = {"version": 1, "fixture": fixtures}
    if not fixtures and inventory == fixture_inventory(json.loads((repo / "lib/hardware-identities-schema.json").read_text())):
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


def nix_string(value):
    return json.dumps(str(value)).replace("${", "\\${")


def deployment_flake(source, destination):
    return """# Managed by sys hardware-deployment. Keep this directory out of Git.
{
  inputs.configuration.url = %s;
  inputs.hardware-identities = { url = %s; flake = false; };
  inputs.configuration.inputs.hardware-identities.follows = "hardware-identities";
  outputs = { configuration, ... }: configuration.outputs;
}
""" % (nix_string("path:" + source), nix_string("path:" + str(destination / "hardware-input")))


def provision_deployment(repo, destination, inventory_file=None, fixtures=False):
    repo = Path(repo).resolve()
    destination = Path(destination).absolute()
    if destination.is_symlink() or destination.resolve().is_relative_to(repo):
        raise ValueError("Deployment must be outside the repository and not a symlink")
    destination = destination.resolve()
    existed = destination.exists()
    if existed:
        if not destination.is_dir() or destination.stat().st_uid != os.getuid() or destination.stat().st_mode & 0o077:
            raise ValueError("Existing deployment must be an owned private directory")
        if {p.name for p in destination.iterdir()} - {'flake.nix', 'flake.lock', 'hardware-input', 'deployment.json', 'source-root'} or any(p.is_symlink() and p.name != 'source-root' for p in destination.iterdir()):
            raise ValueError("Existing deployment contains unexpected files or symlinks")
        try:
            previous = json.loads((destination / 'deployment.json').read_text())
            managed = (previous['version'] == 1 and previous['repository'] == str(repo)
                       and (destination / 'flake.nix').read_text() == deployment_flake(previous['source'], destination)
                       and (destination / 'source-root').is_symlink()
                       and str((destination / 'source-root').readlink()) == previous['source'])
        except (OSError, ValueError, KeyError, TypeError):
            managed = False
        if not managed:
            raise ValueError("Existing deployment is unmanaged or belongs to a different source")
    # Validate/decrypt before touching the existing deployment. A failed lock
    # refresh restores the previous inventory and lock together.
    inventory = read_inventory(repo, inventory_file, fixtures)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.deployment-', dir=destination.parent) as temporary:
        temporary = Path(temporary)
        if existed:
            shutil.copytree(destination, temporary / 'previous', symlinks=True)
        local = temporary / INVENTORY
        local.write_text(json.dumps(inventory))
        local.chmod(0o600)
        try:
            destination.mkdir(mode=0o700, exist_ok=True)
            provision(repo, destination / 'hardware-input', None if fixtures else local, fixtures)
            # Resolve the Git working tree through Nix so ignored/untracked files
            # stay excluded. A store snapshot is lockable even with tracked edits,
            # unlike a dirty Git input on newer Nix versions.
            reference = ("git+file://" + quote(str(repo), safe="/")) if (repo / '.git').exists() else 'path:' + str(repo)
            snapshot = subprocess.run(['nix', 'flake', 'metadata', '--refresh', '--json',
                                       '--no-write-lock-file', reference],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if snapshot.returncode:
                raise RuntimeError('Cannot snapshot configuration source (Nix output withheld)')
            source = json.loads(snapshot.stdout)['path']
            if not re.fullmatch(r'/nix/store/[a-z0-9]{32}-[^/]+', source):
                raise ValueError('Unexpected configuration snapshot path')
            content = deployment_flake(source, destination)
            (destination / 'deployment.json').write_text(json.dumps({
                'version': 1, 'repository': str(repo), 'source': source}) + '\n')
            (destination / 'deployment.json').chmod(0o600)
            (destination / 'flake.nix').write_text(content)
            (destination / 'flake.nix').chmod(0o600)
            # Recreate from the checkout's own dependency lock, keeping local
            # ad-hoc dependency updates from overriding the repository pins.
            (destination / 'flake.lock').unlink(missing_ok=True)
            result = subprocess.run(['nix', 'flake', 'update', '--refresh', '--flake', 'path:' + str(destination),
                                     'configuration', 'hardware-identities'],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode:
                raise RuntimeError('Cannot lock local deployment; previous deployment restored (Nix output withheld)')
            (destination / 'flake.lock').chmod(0o600)
            # The source URL points into the store; keep it available across GC.
            (destination / 'source-root').unlink(missing_ok=True)
            rooted = subprocess.run(['nix-store', '--realise', source, '--add-root',
                                     str(destination / 'source-root'), '--indirect'],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if rooted.returncode:
                raise RuntimeError('Cannot retain deployment source across garbage collection (Nix output withheld)')
        except BaseException:
            shutil.rmtree(destination)
            if existed:
                (temporary / 'previous').rename(destination)
            raise
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    parser.add_argument('--inventory', type=Path, help='Read existing local plaintext instead of decrypting SOPS')
    parser.add_argument('--deployment', action='store_true', help='Create or refresh a machine-local deployment flake and its lock')
    parser.add_argument('--fixtures', action='store_true', help='Generate synthetic data; never install these builds')
    parser.add_argument('--verify-fixtures', action='store_true', help='Verify an existing input for public publishing')
    parser.add_argument('destination', type=Path, help='Local input directory outside the checkout')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.verify_fixtures:
            if args.inventory or args.fixtures or args.deployment:
                raise ValueError('Verification cannot generate or replace input data')
            verify_fixtures(args.repo, args.destination)
        else:
            action = provision_deployment if args.deployment else provision
            print(action(args.repo, args.destination, args.inventory, args.fixtures))
        return 0
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Hardware provisioning stopped: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
