#!/usr/bin/env python3
"""Exercise hash discovery failure handling without fetching Go dependencies."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("updater", Path(__file__).with_name("update-caddy-hashes.py"))
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class UpdateTests(unittest.TestCase):
    def run_update(self, failure=None, url_hint=True):
        with tempfile.TemporaryDirectory() as directory:
            hashes = Path(directory) / "hashes.json"
            original = '{"nixpkgs": "old", "nixpkgs-darwin": "old-pinned"}\n'
            hashes.write_text(original)
            calls = []

            def nix(*args):
                calls.append(args)
                code, stdout, stderr = 0, "", ""
                if args[-1] == "builtins.currentSystem":
                    stdout = "x86_64-linux"
                elif args[0] == "eval":
                    stdout = "/nix/store/example-caddy-source.drv"
                elif "--expr" in args:
                    code = 1
                    drv = "/nix/store/example-caddy-source.drv"
                    if failure == "wrong-derivation":
                        drv = "/nix/store/dependency.drv"
                    stderr = (f"error: hash mismatch in fixed-output derivation '{drv}':\n"
                              f"  likely URL: (unknown)\n"
                              f"  specified: {updater.FAKE_HASH}\n"
                              f"  got: sha256-{'B' * 43}=\n")
                    if not url_hint:
                        stderr = stderr.replace("  likely URL: (unknown)\n", "")
                    if failure == "network":
                        stderr = "error: download failed"
                elif failure == "verification":
                    code = 1
                return subprocess.CompletedProcess(args, code, stdout, stderr)

            with patch.object(updater, "HASHES", hashes), patch.object(updater, "nix", nix):
                if failure:
                    with self.assertRaises(RuntimeError):
                        updater.main()
                    self.assertEqual(hashes.read_text(), original)
                else:
                    updater.main()
                    self.assertEqual(set(json.loads(hashes.read_text()).values()), {"sha256-" + "B" * 43 + "="})
                    self.assertEqual(sum(call[0] == "build" for call in calls), 4)

    def test_refresh_and_verify_both_sources(self):
        self.run_update()

    def test_older_nix_mismatch_format(self):
        self.run_update(url_hint=False)

    def test_reject_unrelated_mismatch(self):
        self.run_update("wrong-derivation")

    def test_reject_network_error(self):
        self.run_update("network")

    def test_restore_hashes_on_verification_failure(self):
        self.run_update("verification")


if __name__ == "__main__":
    unittest.main()
