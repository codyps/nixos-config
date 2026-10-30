#!/usr/bin/env python3
"""Exercise local personalization using invented identities only."""
import copy
import importlib.util
import json
import os
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('runtime', Path(__file__).with_name('hardware-runtime.py'))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


def unpack(data):
    """Independent newc reader; checks alignment, sizes and file modes."""
    result = {}
    offset = 0
    while True:
        assert data[offset:offset + 6] == b'070701'
        fields = [int(data[offset + 6 + i * 8:offset + 14 + i * 8], 16) for i in range(13)]
        offset += 110
        name = data[offset:offset + fields[11] - 1].decode()
        offset = (offset + fields[11] + 3) & ~3
        content = data[offset:offset + fields[6]]
        offset = (offset + fields[6] + 3) & ~3
        if name == 'TRAILER!!!':
            assert offset == len(data)
            return result
        result[name] = (fields[1], content)


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.repo = self.root / 'repo'
        (self.repo / 'lib').mkdir(parents=True)
        self.schema = {'example': {
            'storage': {'luks': {'root': {'uuid': 'uuid', 'volumeKeyId': 'volume-key-id'}},
                        'zfs': {'hostId': 'host-id'}, 'fileSystems': {'/boot': {'uuid': 'uuid'}},
                        'installationDisk': {'byId': 'device-id'}},
            'network': {'mac': 'mac-address', 'iaid': 'integer'},
            'usb': {'hash': 'usb-hash'}}}
        self.fixtures = runtime.hardware.fixture_inventory(self.schema)
        self.values = {'example': {
            'storage': {'luks': {'root': {'uuid': '11111111-2222-3333-4444-555555555555', 'volumeKeyId': 'a' * 64}},
                        'zfs': {'hostId': '12345678'}, 'fileSystems': {'/boot': {'uuid': 'ABCD-1234'}},
                        'installationDisk': {'byId': 'synthetic-test-install-disk'}},
            'network': {'mac': '02:00:00:00:00:01', 'iaid': 42},
            'usb': {'hash': 'A' * 43 + '='}}}
        schema = self.repo / 'lib/hardware-identities-schema.json'
        schema.write_text(json.dumps(self.schema))
        fixture = self.root / 'fixtures.json'
        fixture.write_text(json.dumps(self.fixtures))
        self.source = self.root / 'inventory.json'
        self.source.write_text(json.dumps(self.values))
        self.state = self.root / 'state'
        self.devices = self.root / 'dev'
        pin = self.fixtures['example']['storage']['luks']['root']['volumeKeyId']
        crypttab = self.root / 'crypttab'
        crypttab.write_text('root /dev/disk/by-hardware/example-storage-luks-root-uuid - tpm2-device=auto,fixate-volume-key=' + pin + ',token-timeout=10s,discard\n')
        network = self.root / 'network'
        network.write_text('MACAddress=' + self.fixtures['example']['network']['mac'] + '\nIAID=' + str(self.fixtures['example']['network']['iaid']) + '\n')
        self.manifest = {
            'host': 'example', 'schema': str(schema), 'fixtures': str(fixture), 'byteOrder': 'little',
            'mapper': 'root', 'templates': {'etc/systemd/network/10-lan.network.d/90-hardware.conf': str(network)},
            'initrdTemplates': {'etc/crypttab': str(crypttab)}, 'secrets': {},
        }

    def provision(self):
        runtime.provision(self.manifest, self.state, self.repo, self.source, device_root=self.devices)

    def test_preserves_values_permissions_and_semantic_device_links(self):
        self.provision()
        self.assertEqual(json.loads((self.state / 'input/hardware-identities.json').read_text()), self.values)
        self.assertEqual((self.state / 'input').stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.state / 'input/hardware-identities.json').stat().st_mode & 0o777, 0o600)
        current = self.state / 'current'
        self.assertEqual((current / 'etc/hostid').read_bytes(), bytes.fromhex('78563412'))
        self.assertEqual((current / 'etc/systemd/network/10-lan.network.d/90-hardware.conf').read_text(),
                         'MACAddress=02:00:00:00:00:01\nIAID=42\n')
        self.assertEqual(os.readlink(self.devices / 'disk/by-hardware/example-storage-fileSystems-_boot-uuid'),
                         '../by-uuid/ABCD-1234')
        self.assertEqual(os.readlink(self.state / 'installation-disk'), '/dev/disk/by-id/synthetic-test-install-disk')
        self.assertEqual((current / 'etc/nixos-hardware/devices/ABCD-1234').read_text(),
                         'HARDWARE_LINKS=disk/by-hardware/example-storage-fileSystems-_boot-uuid\n')
        self.assertEqual((current / 'etc').stat().st_mode & 0o777, 0o755)

    def test_overlay_files_exist_before_generators_and_preserve_other_secrets(self):
        secret = self.root / 'secret'
        secret.write_bytes(b'public-test-secret')
        self.manifest['secrets'] = {'/test-secret': str(secret)}
        self.provision()
        initrd = self.root / 'initrd'
        initrd.write_bytes(b'original')
        runtime.append(self.manifest, self.state, initrd)
        self.assertTrue(initrd.read_bytes().startswith(b'original'))
        archive = unpack(initrd.read_bytes()[8:])
        self.assertIn('fixate-volume-key=' + 'a' * 64, archive['etc/crypttab'][1].decode())
        self.assertNotIn(self.fixtures['example']['storage']['luks']['root']['volumeKeyId'].encode(), archive['etc/crypttab'][1])
        self.assertEqual(archive['etc/hostid'][1], bytes.fromhex('78563412'))
        self.assertEqual(archive['.initrd-secrets/test-secret'], (0o100600, b'public-test-secret'))
        self.assertEqual(archive['etc'][0], 0o40755)

    def test_appended_cpio_alignment_after_any_compressed_stream_length(self):
        self.provision()
        for length in range(1, 9):
            initrd = self.root / 'initrd'
            initrd.write_bytes(b'X' * length)
            runtime.append(self.manifest, self.state, initrd)
            offset = (length + 3) & ~3
            self.assertEqual(initrd.read_bytes()[length:offset], b'\0' * (offset - length))
            self.assertIn('etc/crypttab', unpack(initrd.read_bytes()[offset:]))

    def test_initrd_check_reuses_unchanged_and_detects_every_input_change(self):
        self.provision()
        base = self.root / 'base-initrd'
        installed = self.root / 'installed-initrd'
        base.write_bytes(b'base-compressed-image')
        installed.write_bytes(base.read_bytes())
        runtime.append(self.manifest, self.state, installed)
        original = installed.read_bytes()
        stamp = installed.stat().st_mtime_ns
        self.assertTrue(runtime.check_initrd(self.manifest, self.state, installed, base))
        self.assertEqual(installed.stat().st_mtime_ns, stamp)
        base.write_bytes(b'new-compressed-image')
        self.assertFalse(runtime.check_initrd(self.manifest, self.state, installed, base))
        base.write_bytes(b'base-compressed-image')
        template = Path(self.manifest['initrdTemplates']['etc/crypttab'])
        template.write_text(template.read_text() + '# changed template\n')
        self.assertFalse(runtime.check_initrd(self.manifest, self.state, installed, base))
        self.assertEqual(installed.read_bytes(), original)

    def test_initrd_check_detects_secret_changes_and_corrupt_installed_content(self):
        self.provision()
        secret = self.root / 'secret'
        secret.write_bytes(b'synthetic-secret')
        self.manifest['secrets'] = {'test': str(secret)}
        base = self.root / 'base-initrd'
        installed = self.root / 'installed-initrd'
        base.write_bytes(b'base')
        installed.write_bytes(base.read_bytes())
        runtime.append(self.manifest, self.state, installed)
        self.assertTrue(runtime.check_initrd(self.manifest, self.state, installed, base))
        secret.write_bytes(b'changed-secret')
        self.assertFalse(runtime.check_initrd(self.manifest, self.state, installed, base))
        secret.write_bytes(b'synthetic-secret')
        data = bytearray(installed.read_bytes())
        data[0] ^= 1
        installed.write_bytes(data)
        self.assertFalse(runtime.check_initrd(self.manifest, self.state, installed, base))

    def test_null_pin_disables_only_tpm_options_for_fresh_install(self):
        self.values['example']['storage']['luks']['root']['volumeKeyId'] = None
        self.source.write_text(json.dumps(self.values))
        self.provision()
        initrd = self.root / 'new-grub-secrets'
        runtime.append(self.manifest, self.state, initrd)
        crypttab = unpack(initrd.read_bytes())['etc/crypttab'][1].decode()
        self.assertEqual(crypttab.split()[-1], 'discard')
        self.assertEqual(json.loads((self.state / 'current/root-volume-key-id.json').read_text()), None)

    def test_invalid_inventory_leaves_initrd_untouched(self):
        self.provision()
        (self.state / 'input/hardware-identities.json').write_text('{}')
        initrd = self.root / 'initrd'
        initrd.write_bytes(b'unchanged')
        with self.assertRaises(ValueError):
            runtime.append(self.manifest, self.state, initrd)
        self.assertEqual(initrd.read_bytes(), b'unchanged')

    def test_fixture_state_rejected_unless_explicitly_test_only(self):
        runtime.hardware.provision(self.repo, self.state / 'input', fixtures=True)
        with self.assertRaises(ValueError):
            runtime.render(self.manifest, self.state)
        self.manifest['allowFixtures'] = True
        runtime.render(self.manifest, self.state)

    def test_failed_refresh_preserves_inventory_and_rendered_generation(self):
        self.provision()
        previous = (self.state / 'current').resolve()
        self.values['example']['network']['iaid'] = 43
        self.source.write_text(json.dumps(self.values))
        with patch.object(runtime, 'device_links', side_effect=OSError('test failure')):
            with self.assertRaises(OSError):
                self.provision()
        self.assertEqual((self.state / 'current').resolve(), previous)
        self.assertEqual(json.loads((self.state / 'input/hardware-identities.json').read_text())['example']['network']['iaid'], 42)

    def test_missing_template_fails_before_changing_inventory(self):
        self.provision()
        self.manifest['templates']['missing'] = str(self.root / 'missing')
        old = (self.state / 'input/hardware-identities.json').read_bytes()
        with self.assertRaises(OSError):
            self.provision()
        self.assertEqual((self.state / 'input/hardware-identities.json').read_bytes(), old)

    def test_substitution_is_one_pass_and_preserves_value_equal_to_another_marker(self):
        fixtures = {'one': 'first-marker', 'two': 'second-marker'}
        values = {'one': 'second-marker', 'two': 'result'}
        self.assertEqual(runtime.substitute('first-marker second-marker', values, fixtures), 'second-marker result')

    def test_alias_and_big_endian_hostid(self):
        self.assertEqual(runtime.alias('example', ('storage', 'luks', 'z10.1', 'uuid')), 'example-storage-luks-z10_1-uuid')
        self.manifest['byteOrder'] = 'big'
        self.assertEqual(runtime.files(self.manifest, self.values, self.fixtures, self.schema)['etc/hostid'], bytes.fromhex('12345678'))

    def test_duplicate_uuid_has_all_semantic_names(self):
        self.values['example']['storage']['fileSystems']['/boot']['uuid'] = self.values['example']['storage']['luks']['root']['uuid']
        outputs = runtime.files(self.manifest, self.values, self.fixtures, self.schema)
        mapping = outputs['etc/nixos-hardware/devices/11111111-2222-3333-4444-555555555555'].decode()
        self.assertIn('example-storage-luks-root-uuid', mapping)
        self.assertIn('example-storage-fileSystems-_boot-uuid', mapping)

    def test_directory_templates_preserve_unrelated_network_config(self):
        directory = self.root / 'networks'
        directory.mkdir()
        (directory / '10-lan.network').write_text('[Match]\nName=eno1\n')
        self.manifest['initrdTemplates']['etc/systemd/network'] = str(directory)
        outputs = runtime.files(self.manifest, self.values, self.fixtures, self.schema, initrd=True)
        self.assertEqual(outputs['etc/systemd/network/10-lan.network'], b'[Match]\nName=eno1\n')

    def test_combined_inventory_migration_preserves_only_target_host(self):
        self.schema['other'] = {'value': 'string'}
        Path(self.manifest['schema']).write_text(json.dumps(self.schema))
        Path(self.manifest['fixtures']).write_text(json.dumps(runtime.hardware.fixture_inventory(self.schema)))
        self.source.write_text(json.dumps(dict(self.values, other={'value': 'private-other-host'})))
        self.provision()
        self.assertEqual(json.loads((self.state / 'input/hardware-identities.json').read_text()), self.values)
        values, fixtures, schema = runtime.inventory(self.manifest, self.state)
        self.assertEqual(set(values), {'example'})
        self.assertEqual(set(fixtures), {'example'})
        self.assertEqual(set(schema), {'example'})

    def test_legacy_combined_state_remains_readable(self):
        self.provision()
        self.schema['other'] = {'value': 'string'}
        Path(self.manifest['schema']).write_text(json.dumps(self.schema))
        Path(self.manifest['fixtures']).write_text(json.dumps(runtime.hardware.fixture_inventory(self.schema)))
        (self.state / 'input/hardware-identities.json').write_text(json.dumps(dict(self.values, other={'value': 'private-other-host'})))
        self.assertEqual(runtime.inventory(self.manifest, self.state)[0], self.values)

    def test_host_ssh_key_is_converted_locally_and_passed_only_in_environment(self):
        key = self.root / 'persist/ssh/ssh_host_ed25519_key'
        key.parent.mkdir(parents=True)
        key.write_text('private-test-placeholder')
        self.manifest['sshKeyPaths'] = ['/persist/ssh/ssh_host_ed25519_key']
        self.manifest['encryptedInventory'] = str(self.repo / 'secrets/hardware/example.json')
        results = [subprocess.CompletedProcess([], 0, b'private-age-test-placeholder\n', b''),
                   subprocess.CompletedProcess([], 0, json.dumps(self.values['example']).encode(), b'')]
        with patch.object(runtime.subprocess, 'run', side_effect=results) as run:
            runtime.provision(self.manifest, self.state, device_root=self.devices, root=self.root)
        self.assertEqual(run.call_args_list[0].args[0], ['ssh-to-age', '-private-key', '-i', str(key)])
        self.assertEqual(run.call_args_list[1].args[0], ['sops', '--decrypt', self.manifest['encryptedInventory']])
        self.assertIn('private-age-test-placeholder', run.call_args_list[1].kwargs['env']['SOPS_AGE_KEY'])
        self.assertEqual(json.loads((self.state / 'input/hardware-identities.json').read_text()), self.values)

    def test_bad_host_key_does_not_change_existing_state_or_log_private_output(self):
        self.provision()
        before = (self.state / 'input/hardware-identities.json').read_bytes()
        key = self.root / 'host-key'
        key.write_text('private-test-placeholder')
        self.manifest['sshKeyPaths'] = ['/host-key']
        with patch.object(runtime.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, b'private', b'private')):
            with self.assertRaisesRegex(RuntimeError, 'output withheld') as error:
                runtime.provision(self.manifest, self.state, device_root=self.devices, root=self.root)
        self.assertNotIn('private', str(error.exception))
        self.assertEqual((self.state / 'input/hardware-identities.json').read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
