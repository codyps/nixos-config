#!/usr/bin/env python3
"""Account password persistence tests using synthetic hashes, without real accounts."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("passwords", Path(__file__).resolve().parents[1] / "hosts/warbler/account-passwords.py")
passwords = importlib.util.module_from_spec(spec)
spec.loader.exec_module(passwords)


class PasswordTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = self.root / "shadow.d"
        self.store.mkdir(mode=0o700)
        self.inputs = self.root / "inputs"
        self.inputs.mkdir(mode=0o700)
        for account in passwords.ACCOUNTS:
            (self.inputs / account).write_bytes(b"Abcdef-ghijkl-mnopq7-RS")
        self.reader = patch.object(passwords, "private_file", lambda p: p.read_bytes())
        self.reader.start()
        self.addCleanup(self.reader.stop)

    def hash_mock(self, argv, **kwargs):
        self.assertNotIn("Abcdef", " ".join(argv))
        self.assertEqual(kwargs["input"], b"Abcdef-ghijkl-mnopq7-RS\n")
        return subprocess.CompletedProcess(argv, 0, b"$y$test$synthetic-hash\n", b"")

    def initialize(self):
        with patch.object(passwords.subprocess, "run", side_effect=self.hash_mock):
            passwords.initialize(self.store, self.inputs)

    def test_initial_hashes_are_private_and_no_plaintext_is_copied(self):
        self.initialize()
        for account in passwords.ACCOUNTS:
            target = self.store / account
            self.assertEqual(target.read_bytes(), b"$y$test$synthetic-hash\n")
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        self.assertEqual(sorted(p.name for p in self.store.iterdir()), ["cody", "root"])

    def test_retry_preserves_changed_password_without_hashing(self):
        self.initialize()
        (self.store / "cody").write_bytes(b"$y$changed$by-user\n")
        with patch.object(passwords.subprocess, "run") as hashing:
            passwords.initialize(self.store, self.inputs)
            hashing.assert_not_called()
        self.assertEqual((self.store / "cody").read_bytes(), b"$y$changed$by-user\n")

    def test_hash_failure_publishes_nothing(self):
        with patch.object(passwords.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, b"secret", b"secret")):
            with self.assertRaisesRegex(RuntimeError, "output withheld") as failure:
                passwords.initialize(self.store, self.inputs)
        self.assertNotIn("secret", str(failure.exception))
        self.assertEqual(list(self.store.iterdir()), [])

    def test_save_only_requested_account_hash(self):
        shadow = self.root / "shadow"
        shadow.write_bytes(b"root:$y$root$hash:1:0:99999:7:::\ncody:$y$new$hash:1:0:99999:7:::\n")
        passwords.save_changed_password(self.store, shadow, "cody")
        self.assertEqual((self.store / "cody").read_bytes(), b"$y$new$hash\n")
        self.assertFalse((self.store / "root").exists())

    def test_unsupported_account_and_missing_entry_are_rejected(self):
        shadow = self.root / "shadow"
        shadow.write_bytes(b"")
        for account in ("../root", "cody"):
            with self.assertRaises(RuntimeError):
                passwords.save_changed_password(self.store, shadow, account)
        self.assertEqual(list(self.store.iterdir()), [])

    def test_empty_password_cannot_be_persisted(self):
        shadow = self.root / "shadow"
        shadow.write_bytes(b"cody::1:0:99999:7:::\n")
        with self.assertRaises(RuntimeError):
            passwords.save_changed_password(self.store, shadow, "cody")
        self.assertFalse((self.store / "cody").exists())

    def test_locked_password_is_retained(self):
        shadow = self.root / "shadow"
        shadow.write_bytes(b"cody:!$y$old$hash:1:0:99999:7:::\n")
        passwords.save_changed_password(self.store, shadow, "cody")
        self.assertEqual((self.store / "cody").read_bytes(), b"!$y$old$hash\n")


if __name__ == "__main__":
    unittest.main()
