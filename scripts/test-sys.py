import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


DISPATCHER = Path(os.environ.get("SYS_DISPATCHER", Path(__file__).with_name("sys.py")))


class DispatcherTests(unittest.TestCase):
    def test_discovery_forwarding_and_status(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            command = directory / "sys-example"
            command.write_text(f"#!{sys.executable}\nimport sys\nprint(\"\\n\".join(sys.argv[1:]))\nsys.exit(7)\n")
            command.chmod(0o755)
            (directory / "sys-not-executable").write_text("unused")
            env = dict(os.environ, PATH=str(directory))
            def run(*args):
                return subprocess.run([sys.executable, str(DISPATCHER), *args],
                                      env=env, capture_output=True, text=True)
            help_result = run("help")
            self.assertEqual(help_result.returncode, 0)
            self.assertIn("  example\n", help_result.stdout)
            self.assertNotIn("not-executable", help_result.stdout)
            result = run("example", "a b", "$(false)", "--option")
            self.assertEqual(result.returncode, 7)
            self.assertEqual(result.stdout, "a b\n$(false)\n--option\n")
            self.assertEqual(run("missing").returncode, 2)
            self.assertEqual(run("../sys-example").returncode, 2)

    def test_system_and_user_commands_share_one_menu(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first, second = root / "user", root / "system"
            first.mkdir()
            second.mkdir()
            for directory, name, status in [(first, "shared", 3),
                                             (second, "shared", 4),
                                             (second, "system-only", 0)]:
                command = directory / f"sys-{name}"
                command.write_text(f"#!{sys.executable}\nimport sys\nsys.exit({status})\n")
                command.chmod(0o755)
            env = dict(os.environ, PATH=os.pathsep.join(map(str, [first, second])))
            result = subprocess.run([sys.executable, str(DISPATCHER), "shared"], env=env)
            self.assertEqual(result.returncode, 3)
            result = subprocess.run([sys.executable, str(DISPATCHER), "--list"],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.stdout.count("  shared\n"), 1)
            self.assertIn("  system-only\n", result.stdout)


if __name__ == "__main__":
    unittest.main()
