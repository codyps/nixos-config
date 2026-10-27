"""Offline safety checks for the hash-pinned reapply/rollback CLI."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
SCRATCH = Path(os.environ.get("TMPDIR", Path.home() / "AppData/Local/hermes/cache/scratch"))


class DeploymentSafety(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="delta-repair-test-", dir=SCRATCH)
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name) / "delta_ops.py"
        self.original = (ROOT / "delta_ops.original.py").read_bytes()
        self.patched = (ROOT / "delta_ops.patched.py").read_bytes()

    def cli(self, action, script=None):
        return subprocess.run(
            [sys.executable, str(script or ROOT / "reapply.py"), action, "--target", str(self.target)],
            text=True, capture_output=True, check=False,
        )

    def test_check_never_changes_original(self):
        self.target.write_bytes(self.original)
        result = self.cli("check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("original", result.stdout)
        self.assertEqual(self.target.read_bytes(), self.original)

    def test_apply_is_idempotent_and_restore_is_exact(self):
        self.target.write_bytes(self.original)
        for action, expected in [("apply", self.patched), ("apply", self.patched),
                                 ("check", self.patched), ("restore", self.original),
                                 ("restore", self.original)]:
            with self.subTest(action=action):
                result = self.cli(action)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.target.read_bytes(), expected)

    def test_changed_upstream_is_refused_for_every_action(self):
        drift = self.original + b"\n# unexpected upstream change\n"
        for action in ("check", "apply", "restore"):
            with self.subTest(action=action):
                self.target.write_bytes(drift)
                result = self.cli(action)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("Refusing", result.stderr)
                self.assertEqual(self.target.read_bytes(), drift)

    def test_corrupt_patch_source_is_refused_without_writing_target(self):
        copied = Path(self.tmp.name) / "tool"
        copied.mkdir()
        for name in ("reapply.py", "delta_ops.original.py", "delta_ops.patched.py"):
            shutil.copyfile(ROOT / name, copied / name)
        (copied / "delta_ops.patched.py").write_bytes(b"# corrupt source\n")
        self.target.write_bytes(self.original)
        result = self.cli("apply", script=copied / "reapply.py")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("Refusing", result.stderr)
        self.assertEqual(self.target.read_bytes(), self.original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
