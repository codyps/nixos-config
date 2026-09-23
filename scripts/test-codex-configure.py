"""Regression tests for preserving mutable Codex configuration."""

import importlib.util
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

import tomlkit

spec = importlib.util.spec_from_file_location(
    "configure", os.environ.get("CODEX_CONFIGURE_SCRIPT", Path(__file__).with_name("codex-configure.py"))
)
configure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configure)


class ConfigureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.path = self.home / ".codex/config.toml"
        self.cache = self.home / ".cache"

    def write(self, text):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(text)

    def test_seed_is_private_mutable_and_never_rewrites_existing_config(self):
        self.assertTrue(configure.configure(self.path, self.cache, if_missing=True))
        self.assertFalse(self.path.is_symlink())
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.write('# Codex changed this\nsandbox_mode = "read-only"\n')
        before = self.path.read_bytes()
        self.assertFalse(configure.configure(self.path, self.cache, if_missing=True))
        self.assertEqual(self.path.read_bytes(), before)

    def test_update_preserves_comments_fields_and_roots_and_is_idempotent(self):
        self.write('''# My settings
model = "my-model" # keep this
sandbox_mode = "read-only"
[sandbox_workspace_write]
network_access = false
exclude_slash_tmp = true
writable_roots = ["/extra/cache"] # keep roots
[projects."/my/project"]
trust_level = "trusted"
''')
        configure.configure(self.path, self.cache)
        text = self.path.read_text()
        document = tomlkit.parse(text)
        self.assertIn('# keep this', text)
        self.assertIn('# keep roots', text)
        self.assertEqual(document["model"], "my-model")
        self.assertEqual(document["sandbox_mode"], "workspace-write")
        sandbox = document["sandbox_workspace_write"]
        self.assertTrue(sandbox["network_access"])
        self.assertTrue(sandbox["exclude_slash_tmp"])
        self.assertEqual(sandbox["writable_roots"], ["/extra/cache"] + [str(self.cache / c) for c in configure.CACHES])
        self.assertEqual(document["projects"]["/my/project"]["trust_level"], "trusted")
        self.assertFalse(configure.configure(self.path, self.cache))
        self.assertEqual(self.path.read_text(), text)

    def test_bad_input_is_not_overwritten(self):
        for text in ('invalid [', 'sandbox_workspace_write = false', '[sandbox_workspace_write]\nwritable_roots = "oops"'):
            with self.subTest(text=text):
                self.write(text)
                with self.assertRaises((ValueError, tomlkit.exceptions.ParseError)):
                    configure.configure(self.path, self.cache)
                self.assertEqual(self.path.read_text(), text)

    def test_existing_symlink_is_skipped_or_rejected(self):
        self.path.parent.mkdir()
        self.path.symlink_to(self.home / "missing")
        self.assertFalse(configure.configure(self.path, self.cache, if_missing=True))
        with self.assertRaises(ValueError):
            configure.configure(self.path, self.cache)
        self.assertTrue(self.path.is_symlink())

    def test_seed_does_not_clobber_concurrently_created_file(self):
        link = os.link

        def raced_link(source, destination):
            self.path.write_text('# created by Codex\n')
            link(source, destination)

        with patch.object(configure.os, "link", side_effect=raced_link):
            self.assertFalse(configure.configure(self.path, self.cache, if_missing=True))
        self.assertEqual(self.path.read_text(), '# created by Codex\n')
        self.assertEqual(list(self.path.parent.glob('.config-*')), [])

    def test_platform_cache_paths_and_codex_home(self):
        for platform, xdg, suffix in (
            ("darwin", "custom-cache", "Library/Caches"),
            ("linux", "custom-cache", "custom-cache"),
            ("linux", "", ".cache"),
        ):
            with self.subTest(platform=platform, xdg=xdg):
                environment = {"HOME": str(self.home), "CODEX_HOME": str(self.home / 'custom-codex')}
                if xdg:
                    environment["XDG_CACHE_HOME"] = str(self.home / xdg)
                with patch.dict(os.environ, environment, clear=True), patch.object(configure.sys, 'platform', platform), patch.object(configure.sys, 'argv', ['codex-configure']), patch.object(configure, 'configure') as update:
                    configure.main()
                update.assert_called_once_with(self.home / 'custom-codex/config.toml', self.home / suffix, if_missing=False)


if __name__ == "__main__":
    unittest.main()
