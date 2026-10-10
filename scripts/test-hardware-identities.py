#!/usr/bin/env python3
"""Hardware source preparation contracts; no production identifiers or keys."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('hardware', Path(__file__).with_name('hardware-identities.py'))
hardware = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hardware)


class HardwareTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name).resolve()
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        (self.repo / 'lib').mkdir()
        self.schema = {'example': {'wifiMac': 'string', 'iaid': 'integer', 'rootVolumeKeyId': 'string'}}
        (self.repo / 'lib/hardware-identities-schema.json').write_text(json.dumps(self.schema))
        (self.repo / '.gitignore').write_text('hardware-identities.json\nkeys/\n')
        (self.repo / 'flake.nix').write_text('{}')
        self.inventory = {'example': {'wifiMac': '02:00:00:00:00:01', 'iaid': 42, 'rootVolumeKeyId': 'a' * 64}}
        self.local = self.root / 'inventory.json'
        self.local.write_text(json.dumps(self.inventory))
        self.dest = self.root / 'source'

    def prepare(self):
        return hardware.prepare(self.repo, self.dest, self.local)

    def test_exact_values_outside_git_with_private_permissions(self):
        self.prepare()
        self.assertEqual(json.loads((self.dest / hardware.INVENTORY).read_text()), self.inventory)
        self.assertEqual((self.dest / hardware.INVENTORY).stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.dest.stat().st_mode & 0o777, 0o700)
        self.assertFalse((self.repo / hardware.INVENTORY).exists())

    def test_ignored_files_never_copied(self):
        (self.repo / 'keys').mkdir()
        (self.repo / 'keys/private').write_text('not for transfer')
        (self.repo / hardware.INVENTORY).write_text('stale local inventory')
        self.prepare()
        self.assertFalse((self.dest / 'keys').exists())
        self.assertEqual(json.loads((self.dest / hardware.INVENTORY).read_text()), self.inventory)

    def test_tracked_plaintext_rejected(self):
        (self.repo / hardware.INVENTORY).write_text('{}')
        subprocess.run(['git', '-C', str(self.repo), 'add', '-f', hardware.INVENTORY], check=True)
        with self.assertRaisesRegex(ValueError, 'never be tracked'):
            self.prepare()

    def test_tracked_deletion_and_untracked_source(self):
        subprocess.run(['git', '-C', str(self.repo), 'add', 'flake.nix'], check=True)
        (self.repo / 'flake.nix').unlink()
        (self.repo / 'new.nix').write_text('{}')
        self.prepare()
        self.assertFalse((self.dest / 'flake.nix').exists())
        self.assertTrue((self.dest / 'new.nix').exists())

    def test_reject_destination_inside_checkout(self):
        with self.assertRaisesRegex(ValueError, 'outside'):
            hardware.prepare(self.repo, self.repo / 'stage', self.local)

    def test_refuse_overwrite(self):
        self.dest.mkdir()
        with self.assertRaisesRegex(ValueError, 'must not exist'):
            self.prepare()

    def test_symlink_source_rejected(self):
        (self.repo / 'link').symlink_to(self.local)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            self.prepare()

    def test_internal_tracked_source_symlink_preserved(self):
        (self.repo / 'alias.nix').symlink_to('flake.nix')
        self.prepare()
        self.assertTrue((self.dest / 'alias.nix').is_symlink())
        self.assertEqual((self.dest / 'alias.nix').read_text(), '{}')

    def test_missing_or_unknown_fields_rejected(self):
        for data in ({}, {'example': {}}, {'example': dict(self.inventory['example'], extra='no')}):
            with self.assertRaises(ValueError):
                hardware.validate_inventory(data, self.schema)

    def test_wrong_types_and_newlines_rejected(self):
        for key, value in [('wifiMac', 'bad\nvalue'), ('iaid', True), ('iaid', -1), ('wifiMac', None)]:
            data = {'example': dict(self.inventory['example'], **{key: value})}
            with self.assertRaises(ValueError):
                hardware.validate_inventory(data, self.schema)

    def test_fresh_install_null_pin_allowed(self):
        self.inventory['example']['rootVolumeKeyId'] = None
        self.assertEqual(hardware.validate_inventory(self.inventory, self.schema), self.inventory)

    def test_snapshot_can_be_prepared_again_without_key(self):
        self.prepare()
        with patch.object(hardware.subprocess, 'run', side_effect=AssertionError('No decryption needed')):
            hardware.prepare(self.dest, self.root / 'second')
        self.assertEqual(json.loads((self.root / 'second' / hardware.INVENTORY).read_text()), self.inventory)

    def test_sops_decryption_used_for_git_source(self):
        result = subprocess.CompletedProcess([], 0, json.dumps(self.inventory).encode(), b'')
        with patch.object(hardware.subprocess, 'run', return_value=result) as run:
            self.assertEqual(hardware.read_inventory(self.repo), self.inventory)
        self.assertEqual(run.call_args.args[0], ['sops', '--decrypt', str(self.repo / 'secrets/hardware-identities.json')])

    def test_manifest_in_git_checkout_rejected(self):
        (self.repo / hardware.MANIFEST).write_text('[]')
        with self.assertRaisesRegex(ValueError, 'Git checkout'):
            self.prepare()

    def test_failed_decryption_never_creates_destination_or_logs_values(self):
        result = subprocess.CompletedProcess([], 1, b'sensitive', b'sensitive')
        with patch.object(hardware.subprocess, 'run', return_value=result):
            with self.assertRaisesRegex(RuntimeError, 'output withheld') as error:
                hardware.prepare(self.repo, self.dest)
        self.assertNotIn('sensitive', str(error.exception))
        self.assertFalse(self.dest.exists())

    def test_run_propagates_failure_and_cleans_snapshot(self):
        command = ['python3', str(Path(hardware.__file__)), '--repo', str(self.repo), '--inventory', str(self.local),
                   'run', '--', 'python3', '-c', 'import os,sys; print(os.getcwd()); sys.exit(7)']
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertFalse(Path(result.stdout.strip()).exists())


if __name__ == '__main__':
    unittest.main()
