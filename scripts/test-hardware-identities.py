#!/usr/bin/env python3
"""Hardware inventory provisioning contracts; no production identifiers or keys."""
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
        self.schema = {'example': {'wifiMac': 'string', 'iaid': 'integer', 'volumeKeyId': 'volume-key-id'}}
        (self.repo / 'lib/hardware-identities-schema.json').write_text(json.dumps(self.schema))
        (self.repo / '.gitignore').write_text('hardware-identities.json\nkeys/\n')
        (self.repo / 'flake.nix').write_text('{}')
        self.inventory = {'example': {'wifiMac': '02:00:00:00:00:01', 'iaid': 42, 'volumeKeyId': 'a' * 64}}
        self.local = self.root / 'inventory.json'
        self.local.write_text(json.dumps(self.inventory))
        self.dest = self.root / 'source'

    def prepare(self):
        return hardware.provision(self.repo, self.dest, self.local, host='example')

    def test_exact_values_outside_git_with_private_permissions(self):
        self.prepare()
        self.assertEqual(json.loads((self.dest / hardware.INVENTORY).read_text()), self.inventory)
        self.assertEqual((self.dest / hardware.INVENTORY).stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.dest.stat().st_mode & 0o777, 0o700)
        self.assertFalse((self.repo / hardware.INVENTORY).exists())

    def test_reject_destination_inside_checkout(self):
        with self.assertRaisesRegex(ValueError, 'outside'):
            hardware.provision(self.repo, self.repo / 'stage', self.local)

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
        self.inventory['example']['volumeKeyId'] = None
        self.assertEqual(hardware.validate_inventory(self.inventory, self.schema), self.inventory)


    def test_sops_decryption_used_for_git_source(self):
        result = subprocess.CompletedProcess([], 0, json.dumps(self.inventory["example"]).encode(), b'')
        with patch.object(hardware.subprocess, 'run', return_value=result) as run:
            self.assertEqual(hardware.read_inventory(self.repo, host='example'), self.inventory)
        self.assertEqual(run.call_args.args[0], ['sops', '--decrypt', str(self.repo / 'secrets/hardware/example.json')])

    def test_manifest_in_git_checkout_rejected(self):
        (self.repo / hardware.MANIFEST).write_text('[]')
        with self.assertRaisesRegex(ValueError, 'Git checkout'):
            self.prepare()

    def test_failed_decryption_never_creates_destination_or_logs_values(self):
        result = subprocess.CompletedProcess([], 1, b'sensitive', b'sensitive')
        with patch.object(hardware.subprocess, 'run', return_value=result):
            with self.assertRaisesRegex(RuntimeError, 'output withheld') as error:
                hardware.provision(self.repo, self.dest, host='example')
        self.assertNotIn('sensitive', str(error.exception))
        self.assertFalse(self.dest.exists())

    def test_nested_fields_and_synthetic_generation(self):
        schema = {'host': {'storage': {'luks': {'cryptroot': {'volumeKeyId': 'volume-key-id'}}},
                           'network': {'interfaces': {'eno1': {'macAddress': 'mac-address'}}}}}
        fixture = hardware.fixture_inventory(schema)
        self.assertEqual(fixture, hardware.fixture_inventory(schema))
        self.assertEqual(hardware.validate_inventory(fixture, schema), fixture)
        fixture['host']['network']['interfaces']['eno1']['macAddress'] = 'not-a-mac'
        with self.assertRaises(ValueError):
            hardware.validate_inventory(fixture, schema)

    def test_fixture_mode_never_decrypts_and_publish_guard_rejects_production(self):
        with patch.object(hardware, 'read_inventory', wraps=hardware.read_inventory), patch.object(
                hardware.subprocess, 'run', wraps=subprocess.run) as run:
            hardware.provision(self.repo, self.dest, fixtures=True)
        self.assertFalse(any(c.args[0][0] == 'sops' for c in run.call_args_list))
        hardware.verify_fixtures(self.repo, self.dest)
        (self.dest / hardware.INVENTORY).write_text(json.dumps(self.inventory))
        with self.assertRaisesRegex(ValueError, 'differs'):
            hardware.verify_fixtures(self.repo, self.dest)


    def test_fixtures_reject_external_inventory(self):
        with self.assertRaises(ValueError):
            hardware.provision(self.repo, self.dest, self.local, fixtures=True)


    def test_refresh_is_atomic_and_preserves_input_metadata(self):
        self.prepare()
        self.inventory['example']['iaid'] = 43
        self.local.write_text(json.dumps(self.inventory))
        self.prepare()
        self.assertEqual(json.loads((self.dest / hardware.INVENTORY).read_text()), self.inventory)
        self.assertEqual(json.loads((self.dest / 'metadata.json').read_text()), {'version': 1, 'fixture': False})
        self.assertEqual({p.name for p in self.dest.iterdir()}, {hardware.INVENTORY, 'metadata.json'})
        self.assertEqual((self.dest / hardware.INVENTORY).stat().st_mode & 0o777, 0o600)

    def test_refresh_refuses_unexpected_files_and_symlinks(self):
        self.prepare()
        extra = self.dest / 'private-key'
        extra.write_text('never touch this')
        with self.assertRaisesRegex(ValueError, 'unexpected'):
            self.prepare()
        extra.unlink()
        (self.dest / hardware.INVENTORY).unlink()
        (self.dest / hardware.INVENTORY).symlink_to(self.local)
        with self.assertRaisesRegex(ValueError, 'symlinks'):
            self.prepare()
        self.assertEqual(json.loads(self.local.read_text()), self.inventory)

    def test_failed_refresh_preserves_previous_inventory(self):
        self.prepare()
        before = (self.dest / hardware.INVENTORY).read_bytes()
        self.local.write_text('{}')
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual((self.dest / hardware.INVENTORY).read_bytes(), before)

    def test_refuse_symlink_destination(self):
        self.dest.symlink_to(self.root / 'other')
        with self.assertRaisesRegex(ValueError, 'symlink'):
            self.prepare()

    def test_refuse_public_directory(self):
        self.prepare()
        self.dest.chmod(0o755)
        with self.assertRaisesRegex(ValueError, 'private directory'):
            self.prepare()

    def test_refuse_fixture_mode_change(self):
        self.prepare()
        with self.assertRaisesRegex(ValueError, 'fixture mode'):
            hardware.provision(self.repo, self.dest, fixtures=True)

    def test_fixture_data_cannot_be_exported_as_production(self):
        self.local.write_text(json.dumps(hardware.fixture_inventory(self.schema)))
        with self.assertRaisesRegex(ValueError, 'Synthetic inventory'):
            self.prepare()

    def test_fixture_verification_rejects_extra_files(self):
        hardware.provision(self.repo, self.dest, fixtures=True)
        (self.dest / 'unexpected').write_text('extra')
        with self.assertRaisesRegex(ValueError, 'unexpected'):
            hardware.verify_fixtures(self.repo, self.dest)

    def test_fixture_updater_is_deterministic_and_preserves_lock(self):
        spec = importlib.util.spec_from_file_location('updater', Path(__file__).with_name('update-hardware-fixtures.py'))
        updater = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(updater)
        (self.repo / 'config/hardware-fixtures').mkdir(parents=True)
        path = self.repo / 'flake.lock'
        path.write_text('unchanged')
        updater.update(self.repo)
        updater.update(self.repo, check=True)
        self.assertEqual(path.read_text(), 'unchanged')
        fixture = self.repo / 'config/hardware-fixtures' / hardware.INVENTORY
        fixture.write_text('{}')
        with self.assertRaisesRegex(ValueError, 'regeneration'):
            updater.update(self.repo, check=True)

    def test_cli_export_without_nix_or_repository_copy(self):
        result = subprocess.run(['python3', str(Path(hardware.__file__)), '--repo', str(self.repo),
                                 '--host', 'example', '--inventory', str(self.local), str(self.dest)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({p.name for p in self.dest.iterdir()}, {hardware.INVENTORY, 'metadata.json'})

    def add_other_host(self):
        self.schema['other'] = {'value': 'string'}
        (self.repo / 'lib/hardware-identities-schema.json').write_text(json.dumps(self.schema))

    def test_only_selected_sops_file_is_decrypted(self):
        self.add_other_host()
        result = subprocess.CompletedProcess([], 0, json.dumps(self.inventory['example']).encode(), b'')
        with patch.object(hardware.subprocess, 'run', return_value=result) as run:
            self.assertEqual(hardware.read_inventory(self.repo, host='example'), self.inventory)
        run.assert_called_once()
        self.assertEqual(Path(run.call_args.args[0][-1]).name, 'example.json')

    def test_legacy_combined_export_is_reduced_to_selected_host(self):
        self.add_other_host()
        self.local.write_text(json.dumps(dict(self.inventory, other={'value': 'private-other-host'})))
        self.prepare()
        self.assertEqual(json.loads((self.dest / hardware.INVENTORY).read_text()), self.inventory)
        self.assertNotIn('private-other-host', (self.dest / hardware.INVENTORY).read_text())

    def test_raw_host_file_is_supported(self):
        self.local.write_text(json.dumps(self.inventory['example']))
        self.prepare()
        self.assertEqual(json.loads((self.dest / hardware.INVENTORY).read_text()), self.inventory)

    def test_production_export_requires_a_host_without_decrypting(self):
        with patch.object(hardware.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'Select a host'):
                hardware.read_inventory(self.repo)
        run.assert_not_called()

    def test_unknown_host_rejected_without_decrypting(self):
        with patch.object(hardware.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'Unknown hardware host'):
                hardware.read_inventory(self.repo, host='../other')
        run.assert_not_called()

    def test_fixture_host_rejected_even_if_another_host_has_real_values(self):
        self.add_other_host()
        values = hardware.fixture_inventory(self.schema)
        values['other']['value'] = 'private-other-host'
        self.local.write_text(json.dumps(values))
        with self.assertRaisesRegex(ValueError, 'Synthetic inventory'):
            self.prepare()

    def test_wrong_host_export_is_rejected(self):
        self.add_other_host()
        self.local.write_text(json.dumps({'other': {'value': 'private-other-host'}}))
        with self.assertRaises(ValueError):
            self.prepare()

if __name__ == '__main__':
    unittest.main()
