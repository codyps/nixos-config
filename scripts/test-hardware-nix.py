#!/usr/bin/env python3
"""Exercise automatic preparation without production keys or identifiers."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('wrapper', Path(__file__).with_name('hardware-nix.py'))
wrapper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wrapper)


class NixWrapperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / 'repo'
        (self.repo / 'lib').mkdir(parents=True)
        (self.repo / 'secrets/hardware').mkdir(parents=True)
        (self.repo / 'flake.nix').write_text('{}')
        (self.repo / 'lib/hardware-identities-schema.json').write_text('{"host":{"pin":"volume-key-id"}}')
        (self.repo / 'secrets/hardware/host.json').write_text('encrypted revision 1')
        self.data = {'host': {'pin': 'a' * 64}}
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, {'XDG_CACHE_HOME': str(self.root / 'cache')}).start()
        patch.object(wrapper.Path, 'cwd', return_value=self.repo).start()

    def test_local_references_and_files_keep_callers_relative_paths(self):
        args = ['build', '.#host', '--out-link', 'my-result', '--', './program-argument']
        out = wrapper.rewrite(args, self.repo, self.repo, self.root / 'source')
        self.assertEqual(out, ['build', 'path:' + str(self.root / 'source') + '#host', '--out-link', 'my-result', '--', './program-argument'])
        self.assertEqual(wrapper.rewrite(['eval', '--file', 'test.nix'], self.repo, self.repo, self.root / 'source'),
                         ['eval', '--file', str(self.root / 'source/test.nix')])

    def test_decryption_cache_refreshes_when_ciphertext_changes(self):
        with patch.object(wrapper.hardware, 'read_inventory', return_value=self.data) as decrypt:
            first = wrapper.cached_inventory(self.repo)
            self.assertEqual(json.loads(first.read_text()), self.data)
            self.assertEqual(wrapper.cached_inventory(self.repo), first)
            self.assertEqual(decrypt.call_count, 1)
            (self.repo / 'secrets/hardware/host.json').write_text('encrypted revision 2')
            self.assertNotEqual(wrapper.cached_inventory(self.repo), first)
            self.assertEqual(decrypt.call_count, 2)
            self.assertEqual(first.stat().st_mode & 0o777, 0o600)

    def test_unrelated_commands_and_flakes_do_not_decrypt(self):
        with patch.object(wrapper, 'cached_inventory', side_effect=AssertionError('must not decrypt')), patch.object(wrapper.subprocess, 'call', return_value=0) as run:
            for args in [['--version'], ['fmt'], ['flake', 'update'], ['build', 'nixpkgs#hello'], ['eval', '--expr', '1+1']]:
                self.assertEqual(wrapper.main('/real/nix', args), 0)
                self.assertEqual(run.call_args.args[0], ['/real/nix', *args])

    def test_implicit_and_explicit_build_and_develop_prepare_without_chdir(self):
        def prepare(repo, destination, inventory):
            destination.mkdir()
            return destination
        with patch.object(wrapper, 'cached_inventory', return_value=self.root / 'inventory'), patch.object(wrapper.hardware, 'prepare', side_effect=prepare), patch.object(wrapper.subprocess, 'call', return_value=7) as run:
            for args in [['build'], ['build', '-L', '--no-link', '--max-jobs', '2'], ['build', '.#host', '--no-link'], ['develop', '.'], ['develop', '-c', 'pwd'], ['develop', '-c', 'echo', '.'], ['run', '--', '--help'], ['flake', 'check', '--no-build']]:
                self.assertEqual(wrapper.main('/real/nix', args), 7)
                self.assertFalse(run.call_args.kwargs)  # never changes cwd for develop/run or result links
                self.assertTrue(any(a.startswith('path:') for a in run.call_args.args[0]))
                source = next(a[5:].split('#')[0] for a in run.call_args.args[0] if a.startswith('path:'))
                self.assertFalse(Path(source).exists())

    def test_prepared_sources_pass_through(self):
        (self.repo / wrapper.hardware.MANIFEST).write_text('[]')
        with patch.object(wrapper, 'cached_inventory', side_effect=AssertionError('must not decrypt')), patch.object(wrapper.subprocess, 'call', return_value=0):
            self.assertEqual(wrapper.main('/real/nix', ['build', '.#host']), 0)

    def test_failed_decryption_never_runs_nix(self):
        with patch.object(wrapper, 'cached_inventory', side_effect=RuntimeError('decryption failed')), patch.object(wrapper.subprocess, 'call') as run:
            with self.assertRaises(RuntimeError):
                wrapper.main('/real/nix', ['build', '.#host'])
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
