#!/usr/bin/env python3
"""Provisioning control-flow tests; no real TPM, disk or credentials are touched."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "setup", Path(__file__).resolve().parents[1] / "hosts/warbler/tpm-setup.py")
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class ProvisioningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = self.root / "persist"
        self.work = self.root / "work"
        self.work.mkdir()
        self.wifi = self.root / "wifi"
        self.wifi.write_bytes(b"test wifi configuration")
        self.wifi.chmod(0o600)
        self.calls = []
        self.args = SimpleNamespace(wifi_file=self.wifi, ssh_key_file=None, ssh_only=False)
        self.config = {"diskUnlock": True, "disk": "/dev/test", "policy": str(self.wifi), "pcrlock": "pcrlock"}
        self.metadata = {"keyslots": {"0": {"type": "luks2"}}, "tokens": {}}
        self.enrolled = False
        self.fail = None
        for target, value in [("STORE", self.store), ("run", self.fake_run),
                              ("private_input", lambda p: Path(p))]:
            mock = patch.object(setup, target, value)
            mock.start()
            self.addCleanup(mock.stop)
        stdout = contextlib.redirect_stdout(io.StringIO())
        stdout.__enter__()
        self.addCleanup(stdout.__exit__, None, None, None)

    def fake_run(self, *args):
        self.calls.append(args)
        if self.fail and self.fail(args):
            raise subprocess.CalledProcessError(1, args)
        if args[:2] == ("systemd-creds", "encrypt"):
            self.assertIn("--with-key=tpm2", args)
            self.assertIn("--tpm2-pcrs=7", args)
            Path(args[-1]).write_bytes(b"sealed:" + Path(args[-2]).read_bytes())
        elif args[:2] == ("systemd-creds", "decrypt"):
            Path(args[-1]).write_bytes(Path(args[-2]).read_bytes().removeprefix(b"sealed:"))
        elif args[:2] == ("ssh-keygen", "-q"):
            Path(args[-1]).write_bytes(b"fake private key")
        elif args[:2] == ("ssh-keygen", "-y"):
            return b"ssh-ed25519 " + Path(args[-1]).read_bytes().replace(b" ", b"")
        elif args[:2] == ("ssh-keygen", "-lf"):
            return b"test fingerprint"
        elif args[0] == "pcrlock":
            return b"yes\n"
        elif args[:2] == ("cryptsetup", "luksDump"):
            result = json.loads(json.dumps(self.metadata))
            if self.enrolled:
                result["keyslots"]["1"] = {"type": "luks2"}
                # systemd v261 tpm2_make_luks2_json uses an underscore here.
                result["tokens"]["0"] = {"type": "systemd-tpm2", "tpm2_pcrlock": True, "keyslots": ["1"]}
            return json.dumps(result).encode()
        elif args[0] == "systemd-cryptenroll":
            self.assertFalse(any("wipe" in a for a in args))
            self.enrolled = True
        return b""

    def test_credentials_roundtrip_and_repeat_preserve_identity(self):
        setup.credentials(self.args, self.work)
        blobs = {p.name: p.read_bytes() for p in self.store.iterdir()}
        self.calls.clear()
        self.args.wifi_file = None
        setup.credentials(self.args, self.work)
        self.assertEqual(blobs, {p.name: p.read_bytes() for p in self.store.iterdir()})
        self.assertFalse(any(c[:2] == ("systemd-creds", "encrypt") for c in self.calls))
        self.assertTrue(all(p.stat().st_mode & 0o077 == 0 for p in self.store.iterdir()))

    def test_second_credential_failure_publishes_nothing(self):
        self.fail = lambda a: a[:2] == ("systemd-creds", "encrypt") and "--name=ssh-host-key" in a
        with self.assertRaises(subprocess.CalledProcessError):
            setup.credentials(self.args, self.work)
        self.assertEqual(list(self.store.iterdir()), [])

    def test_ethernet_only_generates_once_without_wifi(self):
        self.args.ssh_only = True
        self.args.wifi_file = None
        setup.credentials(self.args, self.work)
        self.assertFalse((self.store / "wifi").exists())
        before = (self.store / "ssh-host-key").read_bytes()
        self.calls.clear()
        setup.credentials(self.args, self.work)
        self.assertEqual(before, (self.store / "ssh-host-key").read_bytes())
        self.assertFalse(any(c[:2] in [("ssh-keygen", "-q"), ("systemd-creds", "encrypt")]
                             for c in self.calls))

    def test_missing_ciphertext_does_not_rotate_saved_identity(self):
        self.args.ssh_only = True
        setup.credentials(self.args, self.work)
        (self.store / "ssh-host-key").unlink()
        self.calls.clear()
        with self.assertRaisesRegex(RuntimeError, "ciphertext is missing"):
            setup.credentials(self.args, self.work)
        self.assertFalse(any(c[:2] == ("ssh-keygen", "-q") for c in self.calls))

    def test_lost_tpm_does_not_rotate_ssh_key(self):
        setup.credentials(self.args, self.work)
        before = (self.store / "ssh-host-key").read_bytes()
        self.fail = lambda a: a[:2] == ("systemd-creds", "decrypt")
        with self.assertRaises(subprocess.CalledProcessError):
            setup.credentials(self.args, self.work)
        self.assertEqual(before, (self.store / "ssh-host-key").read_bytes())

    def test_reseal_from_backup_after_policy_loss(self):
        setup.credentials(self.args, self.work)
        self.args.ssh_key_file = self.work / "ssh-host-key"
        self.fail = lambda a: a[:2] == ("systemd-creds", "decrypt") and str(self.store) in a[-2]
        setup.credentials(self.args, self.work)

    def test_different_ssh_identity_refused(self):
        setup.credentials(self.args, self.work)
        key = self.root / "other-key"
        key.write_bytes(b"different key")
        self.args.ssh_key_file = key
        with self.assertRaisesRegex(RuntimeError, "identity"):
            setup.credentials(self.args, self.work)

    def test_missing_ciphertext_still_checks_backup_identity(self):
        setup.credentials(self.args, self.work)
        (self.store / "ssh-host-key").unlink()
        key = self.root / "wrong-backup"
        key.write_bytes(b"different key")
        self.args.ssh_key_file = key
        with self.assertRaisesRegex(RuntimeError, "identity"):
            setup.credentials(self.args, self.work)

    def test_wrong_recovery_password_never_enrolls(self):
        self.fail = lambda a: a[:2] == ("cryptsetup", "open")
        with patch.object(setup.getpass, "getpass", return_value="wrong"):
            with self.assertRaisesRegex(RuntimeError, "Recovery passphrase"):
                setup.enroll_disk(self.config, self.work)
        self.assertFalse(self.enrolled)

    def test_enrollment_verifies_recovery_and_preserves_slots(self):
        with patch.object(setup.getpass, "getpass", return_value="test passphrase"):
            setup.enroll_disk(self.config, self.work)
        self.assertTrue(self.enrolled)
        verify = next(i for i, c in enumerate(self.calls) if c[:2] == ("cryptsetup", "open"))
        enroll = next(i for i, c in enumerate(self.calls) if c[0] == "systemd-cryptenroll")
        self.assertLess(verify, enroll)

    def test_existing_pcrlock_token_is_not_replaced(self):
        self.metadata["tokens"]["0"] = {"type": "systemd-tpm2", "keyslots": ["1"], "tpm2_pcrlock": True}
        setup.enroll_disk(self.config, self.work)
        self.assertFalse(self.enrolled)

    def test_non_pcrlock_token_requires_explicit_migration(self):
        self.metadata["tokens"]["0"] = {"type": "systemd-tpm2", "keyslots": ["1"]}
        with self.assertRaisesRegex(RuntimeError, "another policy"):
            setup.enroll_disk(self.config, self.work)

    def test_disabled_disk_unlock_refused(self):
        self.config["diskUnlock"] = False
        with self.assertRaisesRegex(RuntimeError, "Enable warbler.tpmUnlock"):
            setup.enroll_disk(self.config, self.work)

    def test_secure_boot_off_refused_before_tools_or_writes(self):
        efi = self.root / "efi"
        efi.mkdir()
        (efi / f"SecureBoot-{setup.EFI_GUID}").write_bytes(bytes(5))
        with patch.object(setup, "EFI", efi), patch.object(setup.os, "geteuid", return_value=0), \
                patch.object(setup.os, "uname", return_value=SimpleNamespace(nodename="warbler")):
            with self.assertRaisesRegex(RuntimeError, "Secure Boot"):
                setup.preflight()
        self.assertEqual(self.calls, [])
        self.assertFalse(self.store.exists())

    def test_only_credential_preflight_allows_a_switched_generation(self):
        efi = self.root / "efi"
        efi.mkdir()
        for name, value in [("SecureBoot", 1), ("SetupMode", 0)]:
            (efi / f"{name}-{setup.EFI_GUID}").write_bytes(bytes(4) + bytes([value]))
        tpm = self.root / "tpm"
        tpm.touch()
        cfg = self.root / "config.json"
        cfg.write_text(json.dumps(self.config))
        paths = {"/dev/tpmrm0": tpm, "/etc/warbler-tpm.json": cfg,
                 "/run/booted-system": self.root / "old-generation",
                 "/run/current-system": self.root / "new-generation"}
        original_stat = setup.os.stat

        def stat(path, *args, **kwargs):
            if str(path) in ["/dev/test-backing", "/dev/mapper/cryptroot"]:
                return SimpleNamespace(st_rdev=123)
            return original_stat(path, *args, **kwargs)

        with patch.object(setup, "EFI", efi), \
                patch.object(setup, "Path", side_effect=lambda p: paths.get(str(p), Path(p))), \
                patch.object(setup.os, "geteuid", return_value=0), \
                patch.object(setup.os, "uname", return_value=SimpleNamespace(nodename="warbler")), \
                patch.object(setup.os, "stat", side_effect=stat), \
                patch.object(setup, "run", return_value=b"/dev/test-backing[/persist]\n"):
            self.assertEqual(setup.preflight(require_current_generation=False), self.config)
            with self.assertRaisesRegex(RuntimeError, "Reboot into the current generation"):
                setup.preflight()

    def test_installer_host_refused(self):
        with patch.object(setup.os, "geteuid", return_value=0), \
                patch.object(setup.os, "uname", return_value=SimpleNamespace(nodename="nixos")):
            with self.assertRaisesRegex(RuntimeError, "installed warbler"):
                setup.preflight()
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    # Match the production command's umask when exercising file creation.
    setup.os.umask(0o077)
    unittest.main()
