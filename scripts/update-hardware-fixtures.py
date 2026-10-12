#!/usr/bin/env python3
"""Refresh synthetic hardware fixtures and their Nix/Lix-compatible lock entry."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('hardware', Path(__file__).with_name('hardware-identities.py'))
hardware = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hardware)


def update(repo, check=False):
    fixtures = repo / 'config/hardware-fixtures'
    schema = json.loads((repo / 'lib/hardware-identities-schema.json').read_text())
    expected = {
        hardware.INVENTORY: json.dumps(hardware.fixture_inventory(schema), indent=2) + '\n',
        'metadata.json': json.dumps({'version': 1, 'fixture': True}) + '\n',
    }
    for name, text in expected.items():
        path = fixtures / name
        if check:
            if path.read_text() != text:
                raise ValueError('Synthetic fixtures need regeneration')
        else:
            path.write_text(text)
    # Fail before hashing if anything other than synthetic data is in this input.
    hardware.verify_fixtures(repo, fixtures)
    nar_hash = subprocess.check_output(['nix', 'hash', 'path', str(fixtures)], text=True).strip()
    lock_path = repo / 'flake.lock'
    lock = json.loads(lock_path.read_text())
    node_name = lock['nodes']['root']['inputs']['hardware-identities']
    node = {
        'flake': False,
        'locked': {'lastModified': 1, 'narHash': nar_hash,
                   'path': './config/hardware-fixtures', 'type': 'path'},
        'original': {'path': './config/hardware-fixtures', 'type': 'path'},
        # Nix >= 2.26 needs the relative input's parent. Lix 2.94 also needs
        # the legacy hash. Both accept this combined entry without rewriting.
        'parent': [],
    }
    if lock['nodes'][node_name] != node:
        if check:
            raise ValueError('Hardware input lock needs normalization')
        lock['nodes'][node_name] = node
        lock_path.write_text(json.dumps(lock, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        update(REPO, args.check)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'{error}; run python3 scripts/update-hardware-fixtures.py\n')
