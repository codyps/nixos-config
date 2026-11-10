#!/usr/bin/env python3
"""Test Crow's generated launcher and private store seeding without booting it.

Usage: python3 scripts/test-crow-container-runtime.py /nix/store/...-crow-ai-start
Build Crow first, then obtain the argument from
nix eval --raw path:.#nixosConfigurations.crow.config.systemd.services.container@crow-ai.serviceConfig.ExecStart
"""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


RUNTIME = Path(sys.argv.pop(1))
SEED = Path(__file__).resolve().parents[1] / "hosts/crow/ai-container-seed-nix.sh"
BASH = shutil.which("bash")


class CrowContainerRuntimeTests(unittest.TestCase):
    def test_launch_boundaries(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            log = directory / "calls.jsonl"
            mock = directory / "nspawn"
            mock.write_text(
                f"#!{sys.executable}\n"
                "import json, os, sys\n"
                "with open(os.environ['CROW_TEST_LOG'], 'a') as output:\n"
                "    output.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            )
            mock.chmod(0o755)
            source, replacements = re.subn(
                r"/nix/store/[^\s]+/bin/systemd-nspawn", str(mock), RUNTIME.read_text()
            )
            self.assertEqual(replacements, 2)
            launcher = directory / "launch"
            launcher.write_text(source)
            root = directory / "existing-guest"
            root.mkdir()
            subprocess.run(
                [BASH, str(launcher)],
                env=os.environ | {
                    "root": str(root),
                    "CROW_TEST_LOG": str(log),
                    "EXTRA_NSPAWN_FLAGS": "--bind=/nix/var/nix/daemon-socket",
                },
                check=True,
            )
            bootstrap, guest = [json.loads(line) for line in log.read_text().splitlines()]
            for call in (bootstrap, guest):
                self.assertIn("--private-users=1048576:1048576", call)
                self.assertIn("--private-users-ownership=map", call)
                self.assertIn("--settings=no", call)
                self.assertIn("--notify-ready=yes", call)
                self.assertFalse(any("daemon-socket" in arg for arg in call))
                self.assertFalse(any("/nix/var/nix/db" in arg for arg in call))
            self.assertIn("--register=no", bootstrap)
            self.assertIn("--bind-ro=/nix/store:/nix/store:idmap", bootstrap)
            self.assertFalse(any(arg.startswith("--bind=/nix/store") for arg in bootstrap))
            self.assertIn("--bind=/var/lib/crow-ai/nix:/nix:idmap", guest)
            self.assertIn("--network-veth", guest)
            # The empty sysfs seed lets nested user namespaces mount sysfs
            # (rootless Docker/runc); only the boot invocation needs it.
            self.assertIn("--bind-ro=/run/crow-ai-sysfs-seed:/run/host/sysfs-seed", guest)
            self.assertFalse(any("sysfs-seed" in arg for arg in bootstrap))
            self.assertFalse(any(arg.startswith(("--bind=/nix/", "--bind-ro=/nix/store:")) for arg in guest))
            self.assertFalse(any("profiles/per-container" in arg for arg in guest))

    def seed(self, directory, paths):
        closure = directory / "paths"
        closure.write_text("\n".join(str(path) for path in paths) + "\n")
        return subprocess.run(
            [BASH, "-euo", "pipefail", str(SEED), str(directory / "nix"), str(closure)],
            capture_output=True,
            text=True,
        )

    def test_seed_copies_without_sharing_inodes_and_preserves_existing_state(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            original = RUNTIME.read_bytes()
            self.assertEqual(self.seed(directory, [RUNTIME]).returncode, 0)
            destination = directory / "nix/store" / RUNTIME.name
            self.assertEqual(destination.read_bytes(), original)
            self.assertNotEqual(destination.stat().st_ino, RUNTIME.stat().st_ino)
            destination.chmod(0o644)
            destination.write_text("guest state")
            self.assertEqual(self.seed(directory, [RUNTIME]).returncode, 0)
            self.assertEqual(destination.read_text(), "guest state")
            self.assertEqual(RUNTIME.read_bytes(), original)

    def test_failed_seed_is_retryable_and_rejects_non_store_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            missing = Path("/nix/store/00000000000000000000000000000000-crow-test-missing")
            self.assertNotEqual(self.seed(directory, [missing]).returncode, 0)
            self.assertEqual(list((directory / "nix/store").iterdir()), [])
            self.assertNotEqual(self.seed(directory, ["/etc/passwd"]).returncode, 0)
            self.assertEqual(self.seed(directory, [RUNTIME]).returncode, 0)


if __name__ == "__main__":
    unittest.main()
