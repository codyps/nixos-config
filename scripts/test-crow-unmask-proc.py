#!/usr/bin/env python3
"""Test Crow's /proc overmount selection without touching real mounts.

Usage: python3 scripts/test-crow-unmask-proc.py /nix/store/...-crow-ai-unmask-proc
Build Crow first, then obtain the argument from
nix eval --raw path:.#nixosConfigurations.crow.config.containers.crow-ai.config.systemd.services.crow-ai-unmask-proc.serviceConfig.ExecStart
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(sys.argv.pop(1))

# Mirrors nspawn's overmounts as seen in a crow-ai mountinfo, including the
# duplicated /proc/sys/net and boot_id rows, unrelated mounts, and paths that
# merely start with "/proc" without a following slash.
MOUNTINFO = """\
23 17 0:21 / / rw,relatime - btrfs /dev/mapper/crow-root rw
184 151 0:75 / /proc rw,nosuid,nodev,noexec,relatime - proc proc rw
185 184 0:75 /sys /proc/sys ro,nosuid,nodev,noexec,relatime - proc proc rw
186 185 0:75 /sys/net /proc/sys/net rw,nosuid,nodev,noexec,relatime - proc proc rw
187 184 0:75 /sys/net /proc/sys/net rw,nosuid,nodev,noexec,relatime - proc proc rw
188 184 0:71 /host/inaccessible/reg /proc/kallsyms ro,nosuid,nodev,noexec - tmpfs tmpfs rw
189 184 0:71 /host/inaccessible/reg /proc/kcore ro,nosuid,nodev,noexec - tmpfs tmpfs rw
190 184 0:71 /host/inaccessible/reg /proc/keys ro,nosuid,nodev,noexec - tmpfs tmpfs rw
191 184 0:71 /host/inaccessible/reg /proc/sysrq-trigger ro,nosuid,nodev,noexec - tmpfs tmpfs rw
192 184 0:71 /host/inaccessible/reg /proc/timer_list ro,nosuid,nodev,noexec - tmpfs tmpfs rw
193 184 0:75 /acpi /proc/acpi ro,nosuid,nodev,noexec,relatime - proc proc rw
194 184 0:75 /asound /proc/asound ro,nosuid,nodev,noexec,relatime - proc proc rw
195 184 0:75 /bus /proc/bus ro,nosuid,nodev,noexec,relatime - proc proc rw
196 184 0:75 /fs /proc/fs ro,nosuid,nodev,noexec,relatime - proc proc rw
197 184 0:75 /irq /proc/irq ro,nosuid,nodev,noexec,relatime - proc proc rw
198 184 0:75 /scsi /proc/scsi ro,nosuid,nodev,noexec,relatime - proc proc rw
148 185 0:71 /host/proc-sys-kernel-random-boot-id /proc/sys/kernel/random/boot_id ro - tmpfs tmpfs rw
174 184 0:71 /host/proc-sys-kernel-random-boot-id /proc/sys/kernel/random/boot_id ro - tmpfs tmpfs rw
135 184 0:71 /host/proc-kmsg /proc/kmsg ro,nosuid,nodev,noexec - tmpfs tmpfs rw
700 17 0:40 /nix/rootfs/nix/store /nix/store rw,noatime - btrfs /dev/mapper/crow-root rw
701 17 0:40 /x /procnotaround rw,relatime - btrfs /dev/mapper/crow-root rw
702 17 0:40 /x /run/crow-nix rw,relatime - btrfs /dev/mapper/crow-root rw
"""

DEPTH_TWO = [
    "/proc/acpi",
    "/proc/asound",
    "/proc/bus",
    "/proc/fs",
    "/proc/irq",
    "/proc/kallsyms",
    "/proc/kcore",
    "/proc/keys",
    "/proc/kmsg",
    "/proc/scsi",
    "/proc/sys",
    "/proc/sysrq-trigger",
    "/proc/timer_list",
]


class CrowUnmaskProcTests(unittest.TestCase):
    def test_targets_are_complete_deduplicated_and_ordered(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "mountinfo"
            fixture.write_text(MOUNTINFO)
            result = subprocess.run(
                [str(SCRIPT), "--dry-run", str(fixture)],
                capture_output=True,
                text=True,
                check=True,
            )
        targets = [
            line.removeprefix("would unmount: ")
            for line in result.stdout.splitlines()
            if line.startswith("would unmount: ")
        ]
        # Duplicated mountinfo rows must yield one target each, and every
        # depth-2 path must survive: "sort -rn -u" collapses same-depth
        # paths to a single representative, which this test guards against.
        self.assertEqual(
            targets[:2],
            ["/proc/sys/kernel/random/boot_id", "/proc/sys/net"],
        )
        self.assertEqual(sorted(targets[2:]), sorted(DEPTH_TWO))
        self.assertEqual(len(targets), len(set(targets)))
        for target in targets:
            self.assertTrue(target.startswith("/proc/"))


if __name__ == "__main__":
    unittest.main()
