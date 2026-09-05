#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent


class CargoCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.cache = self.root / "cache" / "cargo-targets"
        self.cache.mkdir(parents=True)
        self.project = self.root / "projects" / "example"
        self.project.mkdir(parents=True)
        self.link = self.project / "target"
        self.old = self.cache / "old-key"
        self.link.symlink_to(self.old)
        self.env = dict(os.environ, XDG_CACHE_HOME=str(self.cache.parent),
                        CARGO_WRAPPER_DEFAULT_CACHE_SUBDIRECTORY=".cache")
        self.env.pop("CARGO_TARGET_DIR", None)

    def gc(self, *args):
        return subprocess.run([sys.executable, str(SCRIPTS / "cargo-gc.py"), "gc", *args],
                              env=self.env, text=True, capture_output=True, check=True)

    def wrapper(self, *args, configured=False):
        fake = self.root / "cargo"
        fake.write_text(f"#!{sys.executable}\n" +
                        "import json, sys\nfrom pathlib import Path\n" +
                        f"root = Path({str(self.project)!r})\n" +
                        "if 'locate-project' in sys.argv: print(root / 'Cargo.toml')\n" +
                        "elif 'metadata' in sys.argv: print(json.dumps({'workspace_root': str(root), " +
                        f"'target_directory': str(root / {'custom' if configured else 'target'!r})" + "}))\n")
        fake.chmod(0o755)
        subprocess.run(["bash", str(SCRIPTS / "cargo-with-cached-target.sh"), *args],
                       env=dict(self.env, CARGO_WRAPPER_REAL_CARGO=str(fake)),
                       cwd=self.project, check=True, capture_output=True)

    def test_repairs_old_cache_link(self):
        self.wrapper("build")
        self.assertTrue(self.old.is_dir())
        self.assertTrue(self.link.is_symlink())

    def test_repairs_relative_cache_link(self):
        self.link.unlink()
        self.link.symlink_to(os.path.relpath(self.old, self.project))
        self.wrapper("check")
        self.assertTrue(self.old.is_dir())

    def test_non_builds_and_overrides_do_not_repair(self):
        for args in [("metadata",), ("fmt",), ("build", "--help"), ("build", "--target-dir", "custom")]:
            self.wrapper(*args)
            self.assertFalse(self.old.exists())
        self.wrapper("build", configured=True)
        self.assertFalse(self.old.exists())

    def test_clean_dry_run_preserves_broken_link(self):
        self.wrapper("clean", "--dry-run")
        self.assertTrue(self.link.is_symlink())
        self.assertFalse(self.old.exists())
        self.wrapper("clean")
        self.assertFalse(self.link.is_symlink())

    def test_unmanaged_broken_link_untouched(self):
        self.link.unlink()
        outside = self.root / "elsewhere"
        self.link.symlink_to(outside)
        self.wrapper("build")
        self.assertFalse(outside.exists())
        self.gc("--broken-links", "--root", str(self.project), "--delete")
        self.assertTrue(self.link.is_symlink())

    def test_gc_preview_and_delete(self):
        self.old.mkdir()
        (self.old / "artifact").write_text("artifact")
        args = ["--caches", "--broken-links", "--root", str(self.project)]
        preview = self.gc(*args)
        self.assertIn("would remove link:", preview.stdout)
        self.assertTrue(self.old.exists())
        self.gc(*args, "--delete")
        self.assertFalse(self.old.exists())
        self.assertFalse(self.link.is_symlink())

    def test_gc_broken_links_only(self):
        live = self.cache / "live"
        live.mkdir()
        self.gc("--broken-links", "--root", str(self.project), "--delete")
        self.assertTrue(live.exists())
        self.assertFalse(self.link.is_symlink())

    def test_age_checks_contents_and_skips_symlink_caches(self):
        self.old.mkdir()
        (self.old / "recent").write_text("recent")
        os.utime(self.old, (0, 0))
        stale = self.cache / "stale"
        stale.mkdir()
        os.utime(stale, (0, 0))
        (self.cache / "external").symlink_to(self.project)
        self.gc("--older-than", "30", "--delete")
        self.assertTrue(self.old.exists())
        self.assertFalse(stale.exists())
        self.assertTrue(self.project.exists())


if __name__ == "__main__":
    unittest.main()
