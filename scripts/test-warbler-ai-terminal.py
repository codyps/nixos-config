"""Exercise job control through an SSH command supplied as arguments (use -tt)."""
import os
import pty
import select
import subprocess
import sys
import time


master, slave = pty.openpty()
with subprocess.Popen(sys.argv[1:], stdin=slave, stdout=slave, stderr=slave) as session:
    os.close(slave)
    transcript = bytearray()
    pending = bytearray()

    def send(data):
        os.write(master, data)

    def expect(marker):
        deadline = time.monotonic() + 20
        while marker not in pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([master], [], [], remaining)[0]:
                raise AssertionError(f"Timed out waiting for {marker!r}: {transcript!r}")
            chunk = os.read(master, 65536)
            if not chunk:
                raise AssertionError(f"SSH exited before {marker!r}: {transcript!r}")
            transcript.extend(chunk)
            pending.extend(chunk.replace(b"\r", b""))
        del pending[:pending.index(marker) + len(marker)]

    def foreground():
        # The marker comes from the foreground child, after job setup.
        send(b"python3 -c 'import time; print(\"FOREGROUND\", flush=True); time.sleep(60)'\n")
        expect(b"FOREGROUND\n")

    try:
        send(b"stty -echo; unset PROMPT_COMMAND; PS1='PTY> '; printf '\\nREADY\\n'\n")
        expect(b"\nREADY\n")
        expect(b"PTY> ")
        foreground()
        send(b"\x03")
        expect(b"PTY> ")
        send(b"printf '\\nSTATUS=%s\\n' \"$?\"\n")
        expect(b"\nSTATUS=130\n")
        expect(b"PTY> ")
        foreground()
        send(b"\x1a")
        expect(b"PTY> ")
        send(b"jobs -s; printf '\\nSUSPENDED\\n'\n")
        expect(b"Stopped")
        expect(b"\nSUSPENDED\n")
        expect(b"PTY> ")
        send(b"bg; jobs -r; printf '\\nRESUMED\\n'\n")
        expect(b"Running")
        expect(b"\nRESUMED\n")
        expect(b"PTY> ")
        send(b"fg\n")
        expect(b"time.sleep(60)")
        send(b"\x03")
        expect(b"PTY> ")
        send(b"printf '\\nSURVIVED=%s\\n' \"$?\"\n")
        expect(b"\nSURVIVED=130\n")
        expect(b"PTY> ")
        send(b"exit 23\n")
        expect(b"logout")
        assert session.wait(timeout=20) == 23
        assert b"no job control" not in transcript, transcript
        assert b"cannot set terminal process group" not in transcript, transcript
    finally:
        os.close(master)
        if session.poll() is None:
            session.terminate()
            session.wait(timeout=10)

print("SSH terminal: Ctrl-C, Ctrl-Z, bg, fg, and exit status passed")
