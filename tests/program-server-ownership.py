"""Device-free program-cli ownership tests; all vendor commands are fixtures.

Usage: python3 tests/program-server-ownership.py <repository-root>
Requires Bash, coreutils, procps, util-linux and Python from the Nix check.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(sys.argv.pop(1)).resolve()


class ServerOwnership(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.image = self.root / "image.bit"
        self.image.touch()
        self.env = dict(os.environ, FIXTURE=str(self.root),
                        PATH=f"{self.bin}:{os.environ['PATH']}",
                        FPGA_PART_HINT="fixture-part", FDEV_NAME="fixture",
                        COYOTE_NIX_PROGRAM_LOCK_DIR=str(self.root / "lock"),
                        COYOTE_NIX_BUILD_ROOT=str(self.root / "build"),
                        HW_SERVER_LOG=str(self.root / "server.log"))
        for key in ("EXISTING_PID", "EXISTING_UID", "RACE", "VIVADO_RC",
                    "SERVER_FAIL", "HW_SERVER_PORT", "COYOTE_NIX_HW_SERVER_PORT"):
            self.env.pop(key, None)
        self.script("vivado", 'echo programming >> "$FIXTURE/events"\nexit "${VIVADO_RC:-0}"')
        server = self.bin / "hw_server"
        server.write_text(f"#!{sys.executable}\n" + '''import os
from pathlib import Path
import signal
import subprocess
import sys
import time
root = Path(os.environ["FIXTURE"])
child_mode = sys.argv[1:] == ["child"]
name = "child" if child_mode else "server"
def stop(signum, frame):
    with (root / "events").open("a") as stream:
        stream.write(name + " stopped\\n")
    if not child_mode:
        child.wait(timeout=5)
    sys.exit(0)
if os.environ.get("SERVER_FAIL") == "1":
    sys.exit(19)
signal.signal(signal.SIGTERM, stop)
if not child_mode:
    child = subprocess.Popen([sys.executable, __file__, "child"])
(root / (name + ".pid")).write_text(str(os.getpid()))
while True:
    time.sleep(0.1)
''')
        server.chmod(0o755)
        prelude = r'''
activate_xilinx() { :; }
resolve_project_root() { echo "$FIXTURE"; }
require_cmd() { command -v "$1" >/dev/null; }
coyote_nix_hw_server_port() { echo "${COYOTE_NIX_HW_SERVER_PORT:-${HW_SERVER_PORT:-3121}}"; }
coyote_nix_prepare_hw_server_log() { echo "$1"; }
# Deterministic process discovery: never inspect or touch host debug servers.
pgrep() {
  if [ -n "${EXISTING_PID:-}" ] && { [ "${RACE:-0}" = 0 ] || [ -f "$FIXTURE/server.pid" ]; }; then
    echo "$EXISTING_PID"
  fi
  if [ -f "$FIXTURE/server.pid" ]; then
    cat "$FIXTURE/server.pid"
    echo
    cat "$FIXTURE/child.pid"
    echo
  fi
  return 0
}
ps() {
  if [ -n "${EXISTING_PID:-}" ] && [ "${!#}" = "$EXISTING_PID" ]; then
    case "$2" in
      uid=) echo "$EXISTING_UID"; return;;
      user=) echo "uid=$EXISTING_UID pid=$EXISTING_PID hw_server -s tcp::3121"; return;;
    esac
  fi
  command ps "$@"
}
kill() {
  if [ "$1" != -0 ]; then
    printf 'signal %s\n' "$*" >> "$FIXTURE/events"
    # Keep even a regressed implementation from signalling the external fixture.
    if [ -n "${EXISTING_PID:-}" ]; then
      for target in "$@"; do
        [ "$target" != "$EXISTING_PID" ] || return 1
      done
    fi
  fi
  builtin kill "$@"
}
'''
        self.script("program-cli", prelude + (ROOT / "nix/tools/program-cli.sh").read_text())

    def script(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{shutil.which('bash')}\nset -euo pipefail\n" + body + "\n")
        path.chmod(0o755)

    def external(self, foreign=False, port="3121"):
        # Real /proc command line, but no listener and no vendor software.
        proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)",
                                 "-s", f"tcp::{port}"])
        def cleanup():
            proc.terminate()
            proc.wait(timeout=5)
        self.addCleanup(cleanup)
        self.env.update(EXISTING_PID=str(proc.pid),
                        EXISTING_UID=str(os.getuid() + 1 if foreign else os.getuid()))
        return proc

    def events(self):
        path = self.root / "events"
        return path.read_text().splitlines() if path.exists() else []

    def run_program(self, rc):
        result = subprocess.run([str(self.bin / "program-cli"), str(self.image)],
                                env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, rc, result.stdout + result.stderr)
        self.assertFalse((self.root / "lock").exists())
        return result

    def assert_owned_cleanup(self, programming=True):
        events = self.events()
        self.assertEqual(events.count("programming"), int(programming), events)
        self.assertIn("server stopped", events)
        self.assertIn("child stopped", events)
        own_pid = (self.root / "server.pid").read_text()
        self.assertEqual([event for event in events if event.startswith("signal ")],
                         [f"signal -- -{own_pid}"])
        for name in ("server", "child"):
            pid = int((self.root / f"{name}.pid").read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    def test_same_uid_existing_server_is_not_signalled(self):
        proc = self.external()
        result = self.run_program(1)
        self.assertEqual(self.events(), [])
        self.assertIn(str(proc.pid), result.stderr)
        self.assertIn("3121", result.stderr)
        self.assertIsNone(proc.poll())

    def test_foreign_existing_server_is_not_signalled(self):
        proc = self.external(foreign=True)
        self.run_program(1)
        self.assertEqual(self.events(), [])
        self.assertIsNone(proc.poll())

    def test_explicit_unused_port_preserves_existing_server(self):
        proc = self.external()
        self.env["COYOTE_NIX_HW_SERVER_PORT"] = "4121"
        self.run_program(0)
        self.assert_owned_cleanup()
        self.assertIsNone(proc.poll())

    def test_success_cleans_owned_session(self):
        self.run_program(0)
        self.assert_owned_cleanup()

    def test_vivado_failure_cleans_owned_session_and_preserves_status(self):
        self.env["VIVADO_RC"] = "37"
        self.run_program(37)
        self.assert_owned_cleanup()

    def test_server_failure_does_not_program_and_releases_lock(self):
        self.env["SERVER_FAIL"] = "1"
        result = self.run_program(1)
        self.assertNotIn("programming", self.events())
        self.assertIn("exited before programming", result.stderr)

    def test_same_uid_collision_after_launch_only_cleans_owned_session(self):
        proc = self.external()
        self.env["RACE"] = "1"
        self.run_program(1)
        self.assert_owned_cleanup(programming=False)
        self.assertIsNone(proc.poll())

    def test_termination_cleans_owned_session_and_releases_lock(self):
        proc = subprocess.Popen([str(self.bin / "program-cli"), str(self.image)],
                                env=self.env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
        deadline = time.monotonic() + 5
        while not (self.root / "child.pid").exists():
            if proc.poll() is not None or time.monotonic() >= deadline:
                proc.kill()
                stdout, stderr = proc.communicate(timeout=5)
                self.fail(stdout + stderr + " server fixture did not start")
            time.sleep(0.01)
        proc.terminate()
        stdout, stderr = proc.communicate(timeout=10)
        self.assertEqual(proc.returncode, 130, stdout + stderr)
        self.assert_owned_cleanup(programming=False)
        self.assertFalse((self.root / "lock").exists())

    def test_existing_lock_is_preserved_without_signals(self):
        lock = self.root / "lock"
        lock.mkdir()
        (lock / "info").write_text("another invocation\n")
        result = subprocess.run([str(self.bin / "program-cli"), str(self.image)],
                                env=self.env, text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertEqual((lock / "info").read_text(), "another invocation\n")
        self.assertEqual(self.events(), [])


if __name__ == "__main__":
    unittest.main()
