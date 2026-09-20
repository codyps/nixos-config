#!/usr/bin/env python3
"""Non-destructive tests of installer safeguards; never contact a host."""

import contextlib
import importlib.util
import io
import json
import subprocess
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("installer", Path(__file__).with_name("warbler-install.py"))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallTests(unittest.TestCase):
    def setUp(self):
        output = contextlib.redirect_stdout(io.StringIO())
        output.__enter__()
        self.addCleanup(output.__exit__, None, None, None)

    def test_secret_directory_cannot_be_inside_checkout(self):
        with self.assertRaisesRegex(RuntimeError, "outside the checkout"):
            installer.private_path(installer.REPO / "keys/warbler")

    def test_secret_directory_cannot_be_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "link").symlink_to(directory / "real")
            with self.assertRaisesRegex(RuntimeError, "symlinks"):
                installer.private_path(directory / "link")

    def test_existing_bundle_not_regenerated(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(installer, "private_path", return_value=Path(temporary)), \
                    patch.object(installer, "validate_bundle") as validate, \
                    patch.object(installer, "ensure_host_key") as host_key, \
                    patch.object(installer, "ensure_account_passwords") as accounts, \
                    patch.object(installer, "run") as run:
                installer.prepare(temporary)
                self.assertEqual(validate.call_count, 2)
                host_key.assert_called_once()
                accounts.assert_called_once()
                run.assert_not_called()

    def test_account_passwords_generated_once_and_retained(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with patch.object(installer, "run", side_effect=[b"Abcdef-ghijkl-mnopq7-RS", b"Tuvwxy-zabcde-fghij8-KL"]) as generate:
                installer.ensure_account_passwords(directory)
                original = {p.name: p.read_bytes() for p in (directory / "account-passwords").iterdir()}
                installer.ensure_account_passwords(directory)
                self.assertEqual(generate.call_count, 2)
                self.assertEqual(original, {p.name: p.read_bytes() for p in (directory / "account-passwords").iterdir()})
                self.assertNotEqual(original["root"], original["cody"])

    def test_partial_account_passwords_are_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "account-passwords").mkdir(mode=0o700)
            with patch.object(installer, "run") as generate:
                with self.assertRaisesRegex(RuntimeError, "Incomplete account-password"):
                    installer.ensure_account_passwords(directory)
                generate.assert_not_called()

    def test_invalid_generated_password_does_not_publish_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with patch.object(installer, "run", return_value=b"bad"):
                with self.assertRaisesRegex(RuntimeError, "Unexpected"):
                    installer.ensure_account_passwords(directory)
            self.assertFalse((directory / "account-passwords").exists())

    def test_source_inventory_excludes_unlisted_secret(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / "flake.nix").write_text("safe")
            (repo / "secret").write_text("must not transfer")
            with patch.object(installer, "REPO", repo), \
                    patch.object(installer, "run", return_value=b"flake.nix\0"):
                archive = installer.source_archive()
            with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as contents:
                self.assertEqual(contents.getnames(), ["flake.nix"])

    def test_source_refuses_tracked_keys(self):
        with patch.object(installer, "run", return_value=b"keys/private\0"):
            with self.assertRaisesRegex(RuntimeError, "private path"):
                installer.source_archive()

    def test_source_refuses_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / "link").symlink_to("/etc/passwd")
            with patch.object(installer, "REPO", repo), \
                    patch.object(installer, "run", return_value=b"link\0"):
                with self.assertRaisesRegex(RuntimeError, "symlinks"):
                    installer.source_archive()

    def test_host_key_creation_is_repeatable_without_rotation(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            installer.ensure_host_key(directory)
            key = directory / "ssh/ssh_host_ed25519_key"
            original = key.read_bytes()
            installer.ensure_host_key(directory)
            self.assertEqual(key.read_bytes(), original)
            self.assertEqual(key.stat().st_mode & 0o777, 0o600)

    def test_partial_host_identity_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "ssh").mkdir(mode=0o700)
            with self.assertRaisesRegex(RuntimeError, "Incomplete SSH identity"):
                installer.ensure_host_key(directory)

    def test_unregistered_identity_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            installer.ensure_host_key(directory)
            with self.assertRaisesRegex(RuntimeError, "registered SOPS/SSH identity"):
                installer.verify_registered_host_key(directory)

    def inspect(self, **overrides):
        disk = dict(path=installer.DISK, type="disk", size=512110190592,
                    model="SK hynix PC711", mountpoints=[None], fstype=None)
        disk.update(overrides)
        def ssh(command):
            return json.dumps({"blockdevices": [disk]}).encode() if "lsblk" in command else b""
        with patch.object(installer, "ssh", side_effect=ssh):
            installer.inspect_target()

    def test_fresh_expected_nvme_accepted(self):
        self.inspect()

    def test_wrong_disk_or_existing_data_refused(self):
        for override in [dict(path="/dev/sda"), dict(size=4_000_000_000_000),
                         dict(model="Other NVMe"), dict(children=[{}]),
                         dict(mountpoints=["/mnt"]), dict(fstype="btrfs")]:
            with self.subTest(override=override), self.assertRaises(RuntimeError):
                self.inspect(**override)

    def test_ssh_is_strict_and_fail_fast(self):
        with patch.object(installer, "run", return_value=b"") as run:
            installer.ssh("false; true")
            command = run.call_args.args[0]
            self.assertIn("StrictHostKeyChecking=yes", command)
            self.assertIn("set -euo pipefail", command[-1])

    def test_command_error_does_not_echo_secret_output(self):
        import subprocess
        result = subprocess.CompletedProcess(["tool"], 1, b"secret", b"secret")
        with patch.object(installer.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "output withheld") as error:
                installer.run(["tool"])
            self.assertNotIn("secret", str(error.exception))

    def mock_install(self, answer, *, build_only=False):
        calls = []
        def ssh(command, data=None):
            calls.append(command)
            if "mktemp" in command:
                return b"/run/warbler-install.12345678\n"
            if " eval --raw" in command:
                return installer.DISK.encode()
            if " eval --json" in command:
                return b'["system"]'
            if " build --accept-flake-config" in command:
                return b"/nix/store/" + b"a" * 32 + b"-test\n"
            return b""
        with patch.object(installer, "validate_bundle", return_value=Path("/external")), \
                patch.object(installer, "verify_registered_host_key"), \
                patch.object(installer, "validate_account_passwords"), \
                patch.object(installer, "ensure_account_passwords") as accounts, \
                patch.object(installer, "inspect_target"), \
                patch.object(installer, "source_archive", return_value=b"source"), \
                patch.object(installer, "secret_archive", return_value=b"secrets") as secrets, \
                patch.object(installer, "ssh", side_effect=ssh), \
                patch("builtins.input", return_value=answer):
            if build_only:
                installer.install("/external", build_only=True)
                secrets.assert_not_called()
                accounts.assert_not_called()
                self.assertFalse(any("nixos-install --" in cmd for cmd in calls))
                self.assertFalse(any("warbler_volume_key_id=" in cmd for cmd in calls))
            elif not answer:
                with self.assertRaisesRegex(RuntimeError, "cancelled"):
                    installer.install("/external")
                secrets.assert_not_called()
                self.assertFalse(any("nixos-install --" in cmd for cmd in calls))
                self.assertFalse(any("warbler_volume_key_id=" in cmd for cmd in calls))
            else:
                installer.install("/external")
                build = next(i for i, cmd in enumerate(calls) if " build --accept-flake-config" in cmd)
                transfer = next(i for i, cmd in enumerate(calls) if "tar -xf -" in cmd)
                installation = next(i for i, cmd in enumerate(calls) if "nixos-install --" in cmd)
                self.assertLess(build, transfer)
                self.assertLess(transfer, installation)
                self.assertIn("--system /nix/store/", calls[installation])
                self.assertLess(calls[installation].index("cp -a /run/warbler-install.12345678/source/."),
                                calls[installation].index("warbler_volume_key_id="))
                self.assertLess(calls[installation].index("warbler_volume_key_id="),
                                calls[installation].index("nixos-install --"))
                self.assertLess(calls[installation].index("warbler-account-passwords initialize"),
                                calls[installation].index("nixos-install --"))
            self.assertEqual(calls[-1], "rm -rf -- /run/warbler-install.12345678")

    def test_cancel_never_transfers_secrets_or_formats(self):
        self.mock_install("")

    def test_install_builds_before_secret_transfer(self):
        self.mock_install(f"ERASE {installer.DISK} ON {installer.TARGET}")

    def test_build_only_never_transfers_secrets_or_formats(self):
        self.mock_install("", build_only=True)

    def test_record_fresh_volume_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "paths with spaces"
            helper = root / "system/sw/bin/warbler-root-volume-key-id"
            helper.parent.mkdir(parents=True)
            output = root / "checkout/hosts/warbler/volume-identity.nix"
            output.parent.mkdir(parents=True)
            script = installer.volume_identity_script(root / "system", root / "checkout")
            for value, status in [("b" * 64, 0), ("invalid", 0), ("c" * 64, 1)]:
                with self.subTest(value=value, status=status):
                    output.write_text('"existing-pin"\n')
                    helper.write_text(f"#!/bin/sh\nprintf '%s\\n' '{value}'\nexit {status}\n")
                    helper.chmod(0o700)
                    result = subprocess.run(["bash", "-eu", "-c", script], capture_output=True)
                    self.assertEqual(result.stdout, b"")
                    if value == "b" * 64:
                        self.assertEqual(result.returncode, 0)
                        self.assertEqual(output.read_text(), f'"{value}"\n')
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(output.read_text(), '"existing-pin"\n')


if __name__ == "__main__":
    unittest.main()
