#!/usr/bin/env python3
"""Refresh deterministic synthetic hardware fixtures."""
import argparse
import importlib.util
import json
from pathlib import Path

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
    # Reject extra files or anything other than synthetic data.
    hardware.verify_fixtures(repo, fixtures)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        update(REPO, args.check)
    except (OSError, ValueError) as error:
        parser.exit(1, f'{error}; run python3 scripts/update-hardware-fixtures.py\n')
