#!/usr/bin/env python3
"""Exercise tracked-package update and failure handling without builds."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "updater", Path(__file__).with_name("update-tracked-packages.py")
)
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class UpdateTests(unittest.TestCase):
    def test_platform_key(self):
        self.assertEqual(updater.platform_key("x86_64-linux"), "linux")
        self.assertEqual(updater.platform_key("aarch64-linux"), "linux")
        self.assertEqual(updater.platform_key("aarch64-darwin"), "aarch64-darwin")

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        (self.root / "nixpkgs").mkdir()
        self.manifest = self.root / "nixpkgs/tracked-packages.json"
        self.hashes = self.root / "nixpkgs/opencode-hashes.json"
        self.manifest.write_text(json.dumps({
            "opencode": {
                "file": "nixpkgs/opencode.nix",
                "hashAttribute": "node_modules",
                "hashFile": "nixpkgs/opencode-hashes.json",
            },
        }))
        self.original = {
            "aarch64-darwin": "sha256-old-arm",
            "linux": "sha256-old-linux",
            "x86_64-darwin": "sha256-old-intel",
        }
        self.hashes.write_text(json.dumps(self.original))
        self.package_file = self.root / "nixpkgs/opencode.nix"
        self.package_file.write_text("original version\n")

    def tearDown(self):
        self.tempdir.cleanup()

    def run_update(self, failure=None, system="aarch64-darwin", extra_args=None):
        calls = []

        def run(command):
            calls.append(command)
            code, stdout, stderr = 0, "", ""
            if command[0] == "nix-update":
                target_file = self.root / "nixpkgs" / f"{command[-1]}.nix"
                target_file.write_text("updated version\n")
                if failure == "nix-update" or (
                    failure == "one-package" and command[-1] == "badpkg"
                ):
                    code = 1
                    stderr = "error: update failed"
            elif "builtins.currentSystem" in command[-1]:
                stdout = "aarch64-darwin"
            elif command[1] == "eval" and "drvPath" in command[-1]:
                stdout = "/nix/store/example-node_modules.drv"
            elif command[1] == "eval" and ".version" in command[-1]:
                stdout = "2.3.2"
            elif command[1] == "build" and "--expr" in command:
                if failure == "network":
                    code = 1
                    stderr = "error: download failed"
                else:
                    code = 1
                    drv = (
                        "/nix/store/dependency.drv"
                        if failure == "wrong-derivation"
                        else "/nix/store/example-node_modules.drv"
                    )
                    stderr = (
                        f"error: hash mismatch in fixed-output derivation '{drv}':\n"
                        f"  specified: {updater.FAKE_HASH}\n"
                        f"  got: sha256-{'B' * 43}=\n"
                    )
            elif command[1] == "build" and failure == "verification":
                code = 1
                stderr = "error: build failed"
            return subprocess.CompletedProcess(command, code, stdout, stderr)

        args = ["--system", system] + (extra_args or [])
        with patch.object(updater, "ROOT", self.root), \
                patch.object(updater, "MANIFEST", self.manifest), \
                patch.object(updater, "run", run):
            updater.main(args)
        return calls

    def test_refresh_and_verify(self):
        calls = self.run_update()
        updated = json.loads(self.hashes.read_text())
        self.assertEqual(updated["aarch64-darwin"], "sha256-" + "B" * 43 + "=")
        self.assertEqual(updated["linux"], self.original["linux"])
        self.assertEqual(updated["x86_64-darwin"], self.original["x86_64-darwin"])
        self.assertNotIn("version", updated)
        self.assertEqual(sum(call[0] == "nix" and call[1] == "build" for call in calls), 2)

    def test_refresh_linux_uses_shared_key(self):
        calls = self.run_update(system="x86_64-linux")
        updated = json.loads(self.hashes.read_text())
        self.assertEqual(updated["linux"], "sha256-" + "B" * 43 + "=")
        self.assertEqual(updated["aarch64-darwin"], self.original["aarch64-darwin"])
        self.assertTrue(any("packages.x86_64-linux.opencode" in " ".join(call) for call in calls))

    def test_mark_version(self):
        self.run_update(system="x86_64-darwin", extra_args=["--mark-version"])
        updated = json.loads(self.hashes.read_text())
        self.assertEqual(updated["version"], "2.3.2")
        self.assertEqual(updated["x86_64-darwin"], "sha256-" + "B" * 43 + "=")

    def test_seed_missing_platform(self):
        hashes = dict(self.original)
        del hashes["aarch64-darwin"]
        self.hashes.write_text(json.dumps(hashes))
        self.run_update()
        updated = json.loads(self.hashes.read_text())
        self.assertEqual(updated["aarch64-darwin"], "sha256-" + "B" * 43 + "=")

    def test_update_versions(self):
        calls = self.run_update(system="x86_64-linux", extra_args=["--update-versions"])
        update = [call for call in calls if call[0] == "nix-update"]
        self.assertEqual(len(update), 1)
        self.assertEqual(update[0][1:], ["--flake", "--src-only", "opencode"])
        updated = json.loads(self.hashes.read_text())
        self.assertEqual(updated["linux"], "sha256-" + "B" * 43 + "=")
        self.assertEqual(self.package_file.read_text(), "updated version\n")

    def test_update_version_only_package(self):
        self.manifest.write_text(json.dumps({
            "plainpkg": {"file": "nixpkgs/plainpkg.nix"},
        }))
        package_file = self.root / "nixpkgs/plainpkg.nix"
        package_file.write_text("original plain version\n")
        calls = self.run_update(
            system="x86_64-linux", extra_args=["--update-versions"],
        )
        update = [call for call in calls if call[0] == "nix-update"]
        self.assertEqual(len(update), 1)
        self.assertEqual(update[0][1:], ["--flake", "plainpkg"])
        self.assertEqual(package_file.read_text(), "updated version\n")
        self.assertFalse(any(call[0] == "nix" for call in calls))
        self.assertEqual(json.loads(self.hashes.read_text()), self.original)

    def test_update_versions_requires_linux(self):
        with self.assertRaises(RuntimeError):
            self.run_update(system="aarch64-darwin", extra_args=["--update-versions"])
        self.assertEqual(json.loads(self.hashes.read_text()), self.original)

    def test_reject_unrelated_mismatch(self):
        with self.assertRaises(RuntimeError):
            self.run_update("wrong-derivation")
        self.assertEqual(json.loads(self.hashes.read_text()), self.original)

    def test_reject_network_error(self):
        with self.assertRaises(RuntimeError):
            self.run_update("network")
        self.assertEqual(json.loads(self.hashes.read_text()), self.original)

    def test_restore_on_verification_failure(self):
        with self.assertRaises(RuntimeError):
            self.run_update("verification")
        self.assertEqual(json.loads(self.hashes.read_text()), self.original)

    def test_continue_after_one_package_failure(self):
        self.manifest.write_text(json.dumps({
            "opencode": {
                "file": "nixpkgs/opencode.nix",
                "hashAttribute": "node_modules",
                "hashFile": "nixpkgs/opencode-hashes.json",
            },
            "badpkg": {"file": "nixpkgs/badpkg.nix"},
        }))
        bad_file = self.root / "nixpkgs/badpkg.nix"
        bad_file.write_text("original bad version\n")
        with self.assertRaises(RuntimeError):
            self.run_update(
                "one-package", system="x86_64-linux",
                extra_args=["--update-versions"],
            )
        updated = json.loads(self.hashes.read_text())
        self.assertEqual(updated["linux"], "sha256-" + "B" * 43 + "=")
        self.assertEqual(self.package_file.read_text(), "updated version\n")
        self.assertEqual(bad_file.read_text(), "original bad version\n")

    def test_restore_on_update_failure(self):
        with self.assertRaises(RuntimeError):
            self.run_update("nix-update", extra_args=["--update-versions"])
        self.assertEqual(json.loads(self.hashes.read_text()), self.original)
        self.assertEqual(self.package_file.read_text(), "original version\n")


if __name__ == "__main__":
    unittest.main()
