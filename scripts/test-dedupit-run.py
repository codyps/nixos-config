import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


script = Path(os.environ.get("DEDUPIT_RUN_SCRIPT", Path(__file__).resolve().parents[1] / "hosts/warbler/dedupit-run.py"))
spec = importlib.util.spec_from_file_location("dedupit_run", script)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class DedupitRunTests(unittest.TestCase):
    def test_partial_errors_keep_report_and_exit_code_for_next_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result = {"errors": ["Text file busy"], "jobs_completed": 3, "bytes_deduped": 4096}
            command = [sys.executable, "-c", f"import sys; print({json.dumps(result)!r}); sys.exit(2)"]
            self.assertEqual(runner.run(command, directory, 100, interval=0.01, free_bytes=lambda: 1000), 2)
            self.assertEqual(json.loads((directory / "filesystem-result.json").read_text()), result)
            self.assertEqual(json.loads((directory / "filesystem-status.json").read_text())["state"], "finished_with_errors")
            self.assertEqual((directory / "filesystem-result.json").stat().st_mode & 0o777, 0o600)

    def test_low_space_before_start_does_not_launch(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(runner.subprocess, "Popen") as launch:
            self.assertEqual(runner.run(["unused"], temporary, 100, free_bytes=lambda: 99), 75)
            launch.assert_not_called()
            self.assertEqual(json.loads((Path(temporary) / "filesystem-status.json").read_text())["state"], "paused_for_space")

    def test_low_space_stops_child_and_preserves_previous_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            report = directory / "filesystem-result.json"
            report.write_text('{"previous": true}')
            command = [sys.executable, "-c", "import time; time.sleep(60)"]
            free = iter([1000, 1000, 0])
            self.assertEqual(runner.run(command, directory, 100, interval=0.01, free_bytes=lambda: next(free)), 75)
            status = json.loads((directory / "filesystem-status.json").read_text())
            self.assertEqual(status["state"], "paused_for_space")
            self.assertIsNotNone(status["child_exit_code"])
            self.assertEqual(json.loads(report.read_text()), {"previous": True})

    def test_fatal_failure_preserves_previous_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            report = directory / "filesystem-result.json"
            report.write_text('{"previous": true}')
            command = [sys.executable, "-c", "import sys; sys.exit(1)"]
            self.assertEqual(runner.run(command, directory, 100, interval=0.01, free_bytes=lambda: 1000), 1)
            self.assertEqual(json.loads(report.read_text()), {"previous": True})

    def test_sigterm_stops_child_and_records_interruption(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            child = [sys.executable, "-c", "import time; time.sleep(60)"]
            command = [sys.executable, str(script), "--state-directory", temporary, "--minimum-free-bytes", "0", "--", *child]
            process = subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
            try:
                import time
                deadline = time.monotonic() + 5
                status_path = directory / "filesystem-status.json"
                while time.monotonic() < deadline:
                    if status_path.exists() and "pid" in json.loads(status_path.read_text()):
                        break
                    time.sleep(0.01)
                else:
                    self.fail("supervisor did not start its child")
                process.terminate()
                process.communicate(timeout=5)
                self.assertEqual(process.returncode, 143)
                status = json.loads(status_path.read_text())
                self.assertEqual(status["state"], "interrupted")
                with self.assertRaises(ProcessLookupError):
                    os.kill(status["pid"], 0)
            finally:
                if process.poll() is None:
                    process.kill()
                process.communicate()


if __name__ == "__main__":
    unittest.main()
