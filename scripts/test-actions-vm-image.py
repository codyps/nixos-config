#!/usr/bin/env python3
import importlib.util
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "image", Path(__file__).parent / "actions-vm-image/image.py"
)
image = importlib.util.module_from_spec(spec)
spec.loader.exec_module(image)
auto_spec = importlib.util.spec_from_file_location(
    "automation", Path(__file__).parent / "actions-vm-image/automation.py"
)
automation = importlib.util.module_from_spec(auto_spec)
auto_spec.loader.exec_module(automation)


class ImageTests(unittest.TestCase):
    def test_console_automation_requires_recognized_state_and_never_repeats_erase(self):
        def rows(text):
            return [
                {"text": word, "left": "0", "top": "0", "width": "10", "height": "10"}
                for word in text.split()
            ]

        self.assertEqual(
            automation.screen_action(rows("Terminal bash-3.2"), False)[0], "install"
        )
        self.assertIsNone(automation.screen_action(rows("Terminal bash-3.2"), True)[0])
        self.assertEqual(
            automation.screen_action(rows("Reinstall macOS Disk Utility"), False)[0],
            "terminal",
        )
        self.assertEqual(
            automation.screen_action(
                rows("Restore from Time Machine Reinstall macOS Disk Utiity"), False
            )[0],
            "terminal",
        )
        self.assertIsNone(
            automation.screen_action(rows("Terms and Conditions Agree"), False)[0]
        )
        self.assertEqual(
            automation.screen_action(rows("macOS Installer MACOS"), True)[0], "boot"
        )
        self.assertIsNone(
            automation.screen_action(rows("Terminal bash MACOS Installer"), True)[0]
        )

    def test_boot_picker_distinguishes_recovery_from_installed_volume(self):
        recovery = {"text": "macOS"}
        installed = {"text": "MACOS"}
        self.assertEqual(
            automation.screen_action(
                [recovery, {"text": "Base"}, {"text": "System"}, installed], True
            ),
            ("boot", installed),
        )

    def test_bootstrap_identity_comparison_ignores_comments_but_not_key_material(self):
        self.assertEqual(
            automation.public_key("ssh-ed25519 AAAA comment"), "ssh-ed25519 AAAA"
        )
        with self.assertRaises(ValueError):
            automation.public_key('command="bad" ssh-ed25519 AAAA')

    def test_bootstrap_package_has_public_key_and_traversable_root(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            key = root / "key.pub"
            key.write_text("ssh-ed25519 AAAA test\n")
            output = root / "bootstrap.pkg"
            args = SimpleNamespace(public_key=key, output=output)

            def run(*command, **_kwargs):
                if command[0] == "/usr/bin/pkgbuild":
                    payload = Path(command[command.index("--root") + 1])
                    self.assertEqual(payload.stat().st_mode & 0o777, 0o755)
                    self.assertEqual(
                        (
                            payload / "usr/local/share/actions-vm-image/builder.pub"
                        ).read_text(),
                        "ssh-ed25519 AAAA\n",
                    )
                elif command[0] == "/usr/bin/productbuild":
                    output.write_bytes(b"package fixture")

            previous_umask = os.umask(0o077)
            try:
                with patch.object(image, "run", side_effect=run):
                    automation.package(image, args)
            finally:
                os.umask(previous_umask)
            metadata = json.loads(output.with_suffix(".json").read_text())
            self.assertEqual(metadata["sha256"], image.digest(output))

    def test_automatic_build_rejects_wrong_identity_before_creating_workspace(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            runner = root / "runner.tar.gz"
            runner.write_bytes(b"runner")
            package = root / "bootstrap.pkg"
            package.write_bytes(b"package")
            package.with_suffix(".json").write_text(
                json.dumps(
                    {
                        "sha256": image.digest(package),
                        "public_key": "ssh-ed25519 expected",
                    }
                )
            )
            args = SimpleNamespace(
                work_dir=root / "work",
                destination=root / "published",
                timeout=60,
                runner_archive=runner,
                runner_sha256=image.digest(runner),
                bootstrap_package=package,
                identity=root / "key",
            )
            with (
                patch.object(
                    image,
                    "run",
                    return_value=SimpleNamespace(stdout="ssh-ed25519 wrong"),
                ),
                self.assertRaisesRegex(ValueError, "does not match"),
            ):
                automation.build(image, args)
            self.assertFalse(args.work_dir.exists())

    def test_resume_omits_recovery_after_installed_os_was_verified(self):
        for progress, needs_recovery in (
            ({}, True),
            ({"installed": True}, False),
            ({"provisioned": True}, False),
        ):
            with self.subTest(progress=progress), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                work = root / "work"
                work.mkdir()
                (work / "image.json").write_text(json.dumps(progress))
                runner, package = root / "runner.tar.gz", root / "bootstrap.pkg"
                runner.write_bytes(b"runner")
                package.write_bytes(b"bootstrap")
                package.with_suffix(".json").write_text(
                    json.dumps(
                        {
                            "sha256": image.digest(package),
                            "public_key": "ssh-ed25519 key",
                        }
                    )
                )
                args = SimpleNamespace(
                    work_dir=work,
                    destination=root / "published",
                    timeout=60,
                    runner_archive=runner,
                    runner_sha256=image.digest(runner),
                    bootstrap_package=package,
                    identity=root / "key",
                    ssh_port=2229,
                    vnc_display=9,
                )
                with (
                    patch.object(
                        image,
                        "run",
                        return_value=SimpleNamespace(stdout="ssh-ed25519 key"),
                    ),
                    patch.object(image, "download"),
                    patch.object(
                        automation.subprocess,
                        "Popen",
                        return_value=SimpleNamespace(poll=lambda: 0),
                    ) as spawn,
                    self.assertRaisesRegex(RuntimeError, "QEMU exited"),
                ):
                    automation.build(image, args)
                self.assertEqual(
                    "--installer" in spawn.call_args.args[0], needs_recovery
                )

    def test_workspace_lock_excludes_other_mutations(self):
        with (
            tempfile.TemporaryDirectory() as name,
            image.locked(Path(name)),
            self.assertRaisesRegex(ValueError, "in use"),
            image.locked(Path(name)),
        ):
            pass

    def test_disks_console_and_forwarding_are_scoped(self):
        args = SimpleNamespace(vnc_display=9, ssh_port=2229, installer=True)
        manifest = {
            "uuid": "test",
            "memory_mib": 8192,
            "cpus": 4,
            "hardware_args": ["-machine", "q35"],
        }
        command = image.qemu_args(Path("/tmp/build"), manifest, args)
        pairs = {key: command[command.index(key) + 1] for key in ("-vnc", "-netdev")}
        self.assertEqual(pairs["-vnc"], "127.0.0.1:9")
        self.assertIn("hostfwd=tcp:127.0.0.1:2229-:22", pairs["-netdev"])
        drives = [
            command[i + 1] for i, value in enumerate(command) if value == "-drive"
        ]
        writable = [
            d for d in drives if "readonly=on" not in d and "snapshot=on" not in d
        ]
        self.assertEqual(len(writable), 3)
        self.assertTrue(any("/opencore-runtime.qcow2" in d for d in writable))
        self.assertTrue(any("/macos.qcow2" in d for d in writable))
        self.assertTrue(any("/OVMF_VARS.fd" in d for d in writable))
        self.assertNotIn("-no-reboot", command)  # Installation must survive reboots.
        self.assertNotIn("-daemonize", command)
        self.assertNotIn("-virtfs", command)
        args.installer = False
        self.assertNotIn(
            "recovery", " ".join(image.qemu_args(Path("/tmp/build"), manifest, args))
        )

    def test_cannot_publish_unsealed_image_or_replace_version(self):
        with tempfile.TemporaryDirectory() as name:
            work = Path(name)
            args = SimpleNamespace(destination=str(work / "published"))
            with self.assertRaisesRegex(ValueError, "seal"):
                image.publish(work, {"sealed": False}, args)
            Path(args.destination).mkdir()
            with self.assertRaisesRegex(ValueError, "already exists"):
                image.publish(work, {"sealed": True}, args)

    def test_seal_password_uses_stdin_and_failure_retains_diagnostics(self):
        with tempfile.TemporaryDirectory() as name:
            work = Path(name)
            password = work / "password"
            password.write_text("temporary-build-password")
            password.chmod(0o600)
            args = SimpleNamespace(
                builder_password_file=password, require_xcode=False, ssh_user="builder"
            )
            failure = subprocess.CalledProcessError(
                1, "ssh", output=b"compiler passed\n", stderr=b"cleanup failed\n"
            )
            with (
                patch.object(image, "ssh", side_effect=failure) as ssh,
                self.assertRaisesRegex(RuntimeError, "seal-failure.log"),
            ):
                image.seal(work, {"provisioned": True}, args)
            self.assertNotIn("temporary-build-password", ssh.call_args.args[2])
            self.assertIn(b"temporary-build-password", ssh.call_args.kwargs["input"])
            self.assertEqual(
                (work / "seal-failure.log").read_text(),
                "compiler passed\ncleanup failed\n",
            )
            self.assertFalse((work / "image.json").exists())

    def test_recovery_cache_requires_matching_hash(self):
        with tempfile.TemporaryDirectory() as name:
            work = Path(name)
            (work / "BaseSystem.img").write_bytes(b"recovery")
            with self.assertRaisesRegex(ValueError, "checksum"):
                image.download(work, {})
            image.download(
                work, {"recovery_sha256": image.digest(work / "BaseSystem.img")}
            )

    def test_console_rejects_unsupported_text_before_typing_anything(self):
        with patch.object(image, "key") as key:
            with self.assertRaises(ValueError):
                image.type_text(None, "echo café")
            key.assert_not_called()

    def test_ssh_cannot_target_another_forward(self):
        with tempfile.TemporaryDirectory() as name:
            work = Path(name)
            (work / "boot.json").write_text(json.dumps({"ssh_port": 2229}))
            args = SimpleNamespace(ssh_user="builder", ssh_port=22, identity="/tmp/key")
            with self.assertRaisesRegex(ValueError, "port"):
                image.ssh(work, args, "true")

    def test_recovery_disk_guard_uses_whole_disk_metadata_and_refuses_ambiguity(self):
        source = (
            (image.GUEST / "install.sh").read_text().split("# The host controls")[0]
        )
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            (root / "disk-bytes").write_text(str(128 * 1024**3))
            # Execute the actual non-destructive selection code against diskutil's
            # plist contract. No real host diskutil is reachable through this PATH.
            (root / "diskutil").write_text(
                "#!" + sys.executable + "\n"
                "import json, plistlib, sys\n"
                "from pathlib import Path\n"
                "disks = json.loads((Path(__file__).parent / 'disks.json').read_text())\n"
                "if sys.argv[1] == 'list':\n"
                "    print(''.join('/dev/' + name + ' (internal, physical):\\n' for name in disks))\n"
                "else:\n"
                "    sys.stdout.buffer.write(plistlib.dumps(disks[sys.argv[-1].split('/')[-1]]))\n"
            )
            (root / "plutil").write_text(
                "#!" + sys.executable + "\n"
                "import plistlib, sys\n"
                "value = plistlib.loads(sys.stdin.buffer.read()).get(sys.argv[2])\n"
                "if value is None: sys.exit(1)\n"
                "print(str(value).lower() if isinstance(value, bool) else value)\n"
            )
            for executable in ("diskutil", "plutil"):
                (root / executable).chmod(0o755)
            script = source.replace(
                "export PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                "export PATH="
                + shlex.quote(str(root) + os.pathsep + os.environ["PATH"]),
            ).replace("/Volumes/IMAGE_BUILD", str(root))
            script += '\nprintf "%s\\n" "${selected[@]}"\n'
            disk = {"WholeDisk": True, "TotalSize": 128 * 1024**3}
            for disks, expected in [
                ({"disk0": disk}, 0),
                ({"disk0": {**disk, "WholeDisk": False}}, 1),
                ({"disk0": {**disk, "TotalSize": 64 * 1024**3}}, 1),
                ({"disk0": disk, "disk1": disk}, 1),
            ]:
                (root / "disks.json").write_text(json.dumps(disks))
                result = subprocess.run(
                    [shutil.which("bash") or "/bin/bash"],
                    input=script,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(result.returncode, expected, result.stderr)
                if expected == 0:
                    self.assertEqual(result.stdout.strip(), "/dev/disk0")

    @unittest.skipUnless(shutil.which("qemu-img"), "requires qemu-img")
    def test_publication_flattens_real_overlays_and_records_hashes(self):
        with tempfile.TemporaryDirectory() as name:
            work = Path(name)
            image.run("qemu-img", "create", "-f", "qcow2", work / "backing.qcow2", "4M")
            for filename in ("macos.qcow2", "OpenCore.qcow2"):
                image.run(
                    "qemu-img",
                    "create",
                    "-f",
                    "qcow2",
                    "-F",
                    "qcow2",
                    "-b",
                    work / "backing.qcow2",
                    work / filename,
                )
            for filename in ("OVMF_CODE.fd", "OVMF_VARS.fd"):
                (work / filename).write_bytes(b"test firmware")
            manifest = {
                "sealed": True,
                "hardware_args": [],
                "memory_mib": 8192,
                "cpus": 4,
            }
            destination = work / "published"
            image.publish(work, manifest, SimpleNamespace(destination=str(destination)))
            receipt = json.loads((destination / "manifest.json").read_text())
            for filename in ("macos.qcow2", "OpenCore.qcow2"):
                info = json.loads(
                    image.run(
                        "qemu-img",
                        "info",
                        "--output=json",
                        destination / filename,
                        capture_output=True,
                    ).stdout
                )
                self.assertNotIn("backing-filename", info)
                self.assertEqual(
                    receipt["sha256"][filename], image.digest(destination / filename)
                )
                self.assertEqual((destination / filename).stat().st_mode & 0o777, 0o444)

    def test_paths_cannot_inject_qemu_suboptions(self):
        with self.assertRaises(ValueError):
            image.safe_path("/tmp/image,readonly=off")


if __name__ == "__main__":
    unittest.main()
