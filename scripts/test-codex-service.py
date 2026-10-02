"""Exercise supervisor recovery without downloading or running real Codex."""
import os
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import time
import unittest


SCRIPT = Path(os.environ.get("CODEX_SERVICE_SCRIPT", Path(__file__).resolve().parents[1] / "hosts/warbler/codex-service.sh"))
UPDATE = Path(os.environ.get("CODEX_UPDATE_SCRIPT", SCRIPT.with_name("codex-update.sh")))


class SupervisorTest(unittest.TestCase):
    def test_lifecycle_failures_do_not_terminate_supervisor(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            binary = home / ".codex/packages/standalone/current/bin/codex"
            binary.parent.mkdir(parents=True)
            binary.write_text("""#!/bin/sh
echo "$*" >> "$HOME/calls"
case "$*" in
  'app-server daemon bootstrap --remote-control')
    if [ ! -e "$HOME/bootstrapped" ]; then
      touch "$HOME/bootstrapped"
      exit 1
    fi ;;
  'app-server daemon start')
    if [ ! -e "$HOME/checked" ]; then
      touch "$HOME/checked"
      exit 1
    fi ;;
  *) exit 99 ;;
esac
""")
            binary.chmod(0o755)
            helpers = home / "bin"
            helpers.mkdir()
            sleeper = helpers / "sleep"
            sleeper.write_text(f"#!/bin/sh\nexec {shutil.which('sleep')} 0.02\n")
            sleeper.chmod(0o755)
            environment = dict(os.environ, HOME=str(home),
                               CODEX_HOME=str(home / ".codex"),
                               PATH=f"{helpers}:{os.environ['PATH']}")
            with (home / "stderr").open("w+") as stderr:
                process = subprocess.Popen(["bash", str(SCRIPT)], env=environment,
                                           stderr=stderr, start_new_session=True)
                try:
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        calls = (home / "calls").read_text() if (home / "calls").exists() else ""
                        if calls.count("app-server daemon start\n") >= 3:
                            break
                        self.assertIsNone(process.poll())
                        time.sleep(0.02)
                    else:
                        self.fail("supervisor did not recover")
                    self.assertIsNone(process.poll())
                    self.assertEqual(calls.count("app-server daemon bootstrap --remote-control\n"), 2)
                    stderr.seek(0)
                    errors = stderr.read()
                    self.assertIn("bootstrap failed", errors)
                    self.assertIn("leaving existing processes intact", errors)
                    self.assertFalse((home / ".codex/app-server-daemon").exists())
                finally:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=5)

    def test_foreground_uses_selected_daemon_and_execs_it(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            for package in ["standalone", "app-server-daemon"]:
                binary = home / f".codex/packages/{package}/current/bin/codex"
                binary.parent.mkdir(parents=True)
                binary.write_text(f'#!/bin/sh\necho "{package} $$ $*"\n')
                binary.chmod(0o755)
            environment = dict(os.environ, HOME=str(home), CODEX_HOME=str(home / ".codex"))
            with subprocess.Popen(["bash", str(SCRIPT), "foreground"], env=environment,
                                  stdout=subprocess.PIPE, text=True) as process:
                output, _ = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 0)
                self.assertEqual(output.strip(), f"app-server-daemon {process.pid} app-server --remote-control --listen unix:// --managed-daemon")

    def test_updater_only_reloads_after_successful_install(self):
        for install_status, expect_reload in [(1, False), (0, True)]:
            with self.subTest(install_status=install_status), tempfile.TemporaryDirectory() as directory:
                home = Path(directory)
                helpers = home / "bin"
                helpers.mkdir()
                for package in ["standalone", "app-server-daemon"]:
                    root = home / f".codex/packages/{package}"
                    (root / "releases/test/bin").mkdir(parents=True)
                    binary = root / "releases/test/bin/codex"
                    binary.write_text("#!/bin/sh\nexit 0\n")
                    binary.chmod(0o755)
                    (root / "current").symlink_to("releases/test")
                    (root / "auto-update-version").write_text("test\n")
                installer = home / "installer"
                installer.write_text(f'#!/bin/sh\necho "$CODEX_INSTALL_DAEMON_ONLY $CODEX_INSTALL_IF_LATEST $CODEX_UPDATE_FROM_RELEASE" >> "$HOME/installs"\nexit {install_status}\n')
                curl = helpers / "curl"
                curl.write_text('#!/bin/sh\nwhile [ "$1" != -o ]; do shift; done\ncp "$HOME/installer" "$2"\n')
                curl.chmod(0o755)
                systemctl = helpers / "systemctl"
                systemctl.write_text(f'''#!/bin/sh
echo "$*" >> "$HOME/systemctl"
case "$2" in
  is-active) exit 0 ;;
  show) echo {os.getpid()} ;;
  reload) exit 0 ;;
  *) exit 99 ;;
esac
''')
                systemctl.chmod(0o755)
                result = subprocess.run(["bash", str(UPDATE)], env=dict(
                    os.environ, HOME=str(home), CODEX_HOME=str(home / ".codex"),
                    PATH=f"{helpers}:{os.environ['PATH']}"), capture_output=True, text=True, timeout=10)
                calls = (home / "systemctl").read_text() if (home / "systemctl").exists() else ""
                self.assertEqual("--user reload codex-ai.service" in calls, expect_reload, result.stderr)
                if expect_reload:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual((home / "installs").read_text(), "0 1 test\n1 1 test\n")
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(calls, "")


if __name__ == "__main__":
    unittest.main()
