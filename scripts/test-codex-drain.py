"""Prove SIGHUP waits for a real Codex turn, using only a local fake model.

Usage: python3 scripts/test-codex-drain.py /path/to/codex
"""
import http.server
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from websockets.sync.client import unix_connect


def main():
    binary = str(Path(sys.argv[1]).resolve())
    entered = threading.Event()
    release = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()

            def event(kind, **values):
                data = json.dumps(dict(type=kind, **values))
                self.wfile.write(f"event: {kind}\ndata: {data}\n\n".encode())
                self.wfile.flush()

            event("response.created", response={"id": "test-response"})
            entered.set()
            if not release.wait(60):
                return
            item = {"id": "test-message", "type": "message", "role": "assistant",
                    "content": [{"type": "output_text", "text": "drain-test-complete"}]}
            event("response.output_item.added", output_index=0, item=item)
            event("response.output_item.done", output_index=0, item=item)
            event("response.completed", response={"id": "test-response", "status": "completed",
                  "output": [item], "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}})

    model_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=model_server.serve_forever, daemon=True).start()
    server = None
    try:
        with tempfile.TemporaryDirectory(prefix="codex-drain-test-", ignore_cleanup_errors=True) as directory:
            home = Path(directory)
            (home / ".codex").mkdir(mode=0o700)
            (home / ".codex/app-server-control").mkdir(mode=0o700)
            environment = dict(os.environ, CODEX_HOME=str(home / ".codex"), HOME=str(home))
            environment.pop("OPENAI_API_KEY", None)
            environment.pop("CODEX_API_KEY", None)
            config = ["-c", 'model_provider="drain_test"', "-c", 'model="gpt-5.4"',
                      "-c", 'model_providers.drain_test={name="Drain test",base_url="http://127.0.0.1:'
                      + str(model_server.server_port) + '",wire_api="responses",requires_openai_auth=false}']
            socket = home / ".codex/app-server-control/app-server-control.sock"
            with (home / "server.log").open("w+") as log:
                server = subprocess.Popen([binary, "app-server", "--listen", "unix://", "--managed-daemon", *config],
                                          env=environment, cwd=home, stdout=log, stderr=log, start_new_session=True)
                deadline = time.monotonic() + 20
                while not socket.exists():
                    if server.poll() is not None or time.monotonic() > deadline:
                        log.seek(0)
                        raise AssertionError(log.read())
                    time.sleep(0.05)
                websocket = unix_connect(str(socket), compression=None, max_size=None)

                def send(message):
                    websocket.send(json.dumps(message))

                def request(ident, method, params):
                    send(dict(id=ident, method=method, params=params))
                    deadline = time.monotonic() + 20
                    while True:
                        message = json.loads(websocket.recv(timeout=max(0.01, deadline - time.monotonic())))
                        if message.get("id") == ident:
                            assert "error" not in message, message
                            return message["result"]

                request(1, "initialize", {"clientInfo": {"name": "drain-test", "version": "1"}})
                send({"method": "initialized"})
                thread = request(2, "thread/start", {"cwd": directory, "approvalPolicy": "never"})
                request(3, "turn/start", {"threadId": thread["thread"]["id"],
                                         "input": [{"type": "text", "text": "Reply with a short greeting."}]})
                assert entered.wait(20), "Codex did not reach the local fake model"
                for _ in range(2):
                    server.send_signal(signal.SIGHUP)
                    time.sleep(1)
                    assert server.poll() is None, "drain interrupted the active turn"
                release.set()
                assert server.wait(timeout=30) == 0
                # Graceful shutdown can close the socket before its final
                # notification is delivered. Check the persisted completed turn.
                events = [json.loads(line) for path in (home / ".codex/sessions").rglob("*.jsonl")
                          for line in path.read_text().splitlines()]
                completed = [event for event in events if event.get("type") == "event_msg"
                             and event.get("payload", {}).get("type") in ("task_complete", "turn_complete")]
                assert completed, [event.get("payload", {}).get("type") for event in events]
                assert "drain-test-complete" in json.dumps(completed), completed
                websocket.close()
                print("PASS: repeated SIGHUP preserved the active turn, then exited gracefully")
    finally:
        release.set()
        for process in [server]:
            if process is not None and process.poll() is None:
                process.kill()
                process.wait(timeout=10)
        if server is not None:
            try:
                os.killpg(server.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if "directory" in locals():
            shutil.rmtree(directory, ignore_errors=True)
        model_server.shutdown()


if __name__ == "__main__":
    main()
