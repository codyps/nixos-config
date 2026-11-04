"""Simulate disk pressure without filling a real filesystem or touching Codex."""
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SCRIPT = Path(os.environ.get("CODEX_STORAGE_SCRIPT", Path(__file__).resolve().parents[1] / "nixos-modules/ai-container/codex-storage.py"))
spec = importlib.util.spec_from_file_location("storage", SCRIPT)
storage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(storage)


class StorageTest(unittest.TestCase):
    def test_uses_space_available_to_unprivileged_user(self):
        with patch.object(storage.os, "statvfs", return_value=SimpleNamespace(
                f_bavail=2, f_bfree=100, f_frsize=4096)):
            self.assertEqual(storage.available_bytes("/state"), 8192)

    def test_low_space_fails_with_actionable_error(self):
        errors = io.StringIO()
        with patch.object(storage, "available_bytes", return_value=0), redirect_stderr(errors):
            self.assertEqual(storage.main(["/state", "--min-free-gib", "10"]), 1)
        self.assertIn("only 0.00 GiB", errors.getvalue())
        self.assertIn("need 10 GiB", errors.getvalue())

    def test_waits_through_pressure_then_recovers_without_log_storm(self):
        errors, output = io.StringIO(), io.StringIO()
        with patch.object(storage, "available_bytes", side_effect=[0, 0, 2 * storage.GIB]), \
                patch.object(storage.time, "sleep") as sleep, \
                patch.object(storage.time, "monotonic", return_value=1), \
                redirect_stderr(errors), redirect_stdout(output):
            self.assertEqual(storage.main(["/state", "--min-free-gib", "2", "--wait"]), 0)
        self.assertEqual(sleep.call_count, 2)
        self.assertEqual(errors.getvalue().count("Waiting before starting"), 1)
        self.assertIn("recovered", output.getvalue())

    def test_sufficient_space_does_not_delay_startup(self):
        with patch.object(storage, "available_bytes", return_value=2 * storage.GIB), \
                patch.object(storage.time, "sleep") as sleep:
            self.assertEqual(storage.main(["/state", "--min-free-gib", "2", "--wait"]), 0)
        sleep.assert_not_called()

    def test_missing_path_fails_explicitly(self):
        errors = io.StringIO()
        with patch.object(storage, "available_bytes", side_effect=FileNotFoundError("missing")), redirect_stderr(errors):
            self.assertEqual(storage.main(["/missing"]), 1)
        self.assertIn("Cannot check Codex storage", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
