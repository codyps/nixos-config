import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest import mock


script = Path(os.environ.get("BTRFS_BALANCE_SCRIPT", Path(__file__).with_name("btrfs-balance.py")))
spec = importlib.util.spec_from_file_location("btrfs_balance", script)
maintenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(maintenance)


class BalanceTests(unittest.TestCase):
    def run_balance(self, mounts, statuses=None, fail_on=None):
        calls = []
        def run(command, **kwargs):
            calls.append(command)
            if command[0] == "findmnt":
                mounted = mounts[command[3]]
                if mounted is None:
                    return subprocess.CompletedProcess(command, 1, "", "")
                return subprocess.CompletedProcess(command, 0, json.dumps({"filesystems": [mounted]}), "")
            code = (statuses or {}).get(command[-1], 0) if command[2] == "status" else 0
            if fail_on and command[2] == "start" and command[-1] == fail_on:
                raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(command, code)
        with mock.patch.object(maintenance.subprocess, "run", side_effect=run):
            result = maintenance.balance(list(mounts))
        return result, [c for c in calls if c[0] == "btrfs" and c[2] == "start"]

    def test_subvolume_mounts_are_balanced_once_with_limited_filters(self):
        fs = {"fstype": "btrfs", "uuid": "fixture-a", "options": "rw,subvolid=256"}
        result, starts = self.run_balance({"/": fs, "/home": fs, "/persist": fs})
        self.assertEqual(result, 0)
        self.assertEqual(starts, [
            ["btrfs", "balance", "start", "-dusage=0", "-musage=0", "/"],
            ["btrfs", "balance", "start", "-dusage=50,limit=8", "/"],
        ])

    def test_read_only_alias_does_not_hide_writable_mount(self):
        result, starts = self.run_balance({
            "/read only": {"fstype": "btrfs", "uuid": "fixture-a", "options": "ro"},
            "/writable path": {"fstype": "btrfs", "uuid": "fixture-a", "options": "rw"},
        })
        self.assertEqual(result, 0)
        self.assertEqual([c[-1] for c in starts], ["/writable path"] * 2)

    def test_unmounted_or_replaced_filesystems_are_skipped(self):
        result, starts = self.run_balance({"/missing": None, "/replaced": {"fstype": "ext4", "options": "rw"}})
        self.assertEqual(result, 0)
        self.assertEqual(starts, [])

    def test_enospc_is_reported_without_blocking_other_filesystems(self):
        result, starts = self.run_balance({
            "/a": {"fstype": "btrfs", "uuid": "fixture-a", "options": "rw"},
            "/b": {"fstype": "btrfs", "uuid": "fixture-b", "options": "rw"},
        }, fail_on="/a")
        self.assertEqual(result, 1)
        self.assertEqual([c[-1] for c in starts], ["/a", "/b", "/b"])

    def test_missing_uuid_refuses_balance(self):
        result, starts = self.run_balance({"/": {"fstype": "btrfs", "uuid": None, "options": "rw"}})
        self.assertEqual(result, 1)
        self.assertEqual(starts, [])

    def test_active_balance_is_left_running(self):
        result, starts = self.run_balance({"/": {"fstype": "btrfs", "uuid": "fixture-a", "options": "rw"}}, statuses={"/": 1})
        self.assertEqual(result, 0)
        self.assertEqual(starts, [])


if __name__ == "__main__":
    unittest.main()
