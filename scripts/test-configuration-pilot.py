#!/usr/bin/env python3
"""Check pilot reporting without building or publishing configurations."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, patch

spec = importlib.util.spec_from_file_location(
    "pilot", Path(__file__).with_name("configuration-pilot.py"))
pilot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pilot)


class PilotTests(unittest.TestCase):
    def run_pilot(self, exit_code=0, closure=None, info_failure=False):
        with tempfile.TemporaryDirectory() as directory:
            previous = os.getcwd()
            os.chdir(directory)
            self.addCleanup(os.chdir, previous)
            process = MagicMock()
            process.__enter__.return_value = process
            process.wait.side_effect = [subprocess.TimeoutExpired("nix", 2), exit_code]
            free = [1000, 800, 500, 700]
            with (
                patch.dict(os.environ, {
                    "GITHUB_STEP_SUMMARY": "summary.md",
                    "GITHUB_SHA": "caller-commit",
                    "CACHE_REVISION": "updated-commit",
                }),
                patch.object(pilot.shutil, "disk_usage", side_effect=[
                    MagicMock(free=value) for value in free]),
                patch.object(pilot.subprocess, "Popen", return_value=process) as build,
                patch.object(pilot.subprocess, "run") as info,
            ):
                if info_failure:
                    info.side_effect = subprocess.CalledProcessError(1, "nix path-info")
                    with self.assertRaises(subprocess.CalledProcessError):
                        pilot.main('.#homeConfigurations."cody@arch1".activationPackage')
                    result = None
                else:
                    info.return_value.stdout = json.dumps(closure)
                    result = pilot.main('.#homeConfigurations."cody@arch1".activationPackage')
                self.assertEqual(build.call_args.args[0][-1],
                                 '.#homeConfigurations."cody@arch1".activationPackage')
                if exit_code:
                    info.assert_not_called()
                metrics = json.loads(Path("pilot/metrics.json").read_text())
                self.assertEqual(metrics["revision"], "updated-commit")
                self.assertEqual(metrics["minimum_sampled_free_bytes"], 500)
                self.assertEqual(metrics["peak_sampled_disk_growth_bytes"], 500)
                self.assertIn("cody@arch1", Path("summary.md").read_text())
            os.chdir(previous)
            return result, metrics

    def test_success_with_both_nix_json_formats(self):
        for closure in ([{"closureSize": 123}], {"/nix/store/root": {"closureSize": 123}}):
            with self.subTest(closure=closure):
                result, metrics = self.run_pilot(closure=closure)
                self.assertEqual(result, 0)
                self.assertEqual(metrics["closure_bytes"], 123)

    def test_failed_build_preserves_status_and_report(self):
        result, metrics = self.run_pilot(exit_code=42)
        self.assertEqual(result, 42)
        self.assertEqual(metrics["build_exit_code"], 42)
        self.assertNotIn("closure_bytes", metrics)

    def test_failed_size_query_still_writes_build_measurements(self):
        _, metrics = self.run_pilot(info_failure=True)
        self.assertEqual(metrics["build_exit_code"], 0)
        self.assertIn("build_seconds", metrics)


if __name__ == "__main__":
    unittest.main()
