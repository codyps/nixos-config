"""Exercise remote-control recovery against a local Unix WebSocket server."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest

from websockets.sync.server import unix_serve


SCRIPT = Path(os.environ.get("CODEX_REMOTE_CONTROL_SCRIPT", Path(__file__).resolve().parents[1] / "nixos-modules/ai-container/codex-remote-control.py"))
spec = importlib.util.spec_from_file_location("remote_control", SCRIPT)
remote_control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote_control)


class RecoveryTest(unittest.TestCase):
    def exercise(self, error=False):
        calls = []
        failures = []

        def handle(websocket):
            try:
                initialize = json.loads(websocket.recv(timeout=5))
                calls.append(initialize)
                websocket.send(json.dumps({"id": 1, "result": {}}))
                calls.append(json.loads(websocket.recv(timeout=5)))
                enable = json.loads(websocket.recv(timeout=5))
                calls.append(enable)
                # Notifications can arrive before the matching RPC response.
                websocket.send(json.dumps({"method": "remoteControl/status/changed", "params": {"status": "disabled"}}))
                response = {"id": 2}
                response.update({"error": {"code": -32000, "message": "signed out"}} if error else {"result": {"status": "connecting"}})
                websocket.send(json.dumps(response))
            except Exception as exception:
                failures.append(exception)

        with tempfile.TemporaryDirectory() as directory:
            socket_path = str(Path(directory) / "control.sock")
            with unix_serve(handle, socket_path, compression=None) as server:
                worker = threading.Thread(target=server.serve_forever)
                worker.start()
                try:
                    if error:
                        with self.assertRaisesRegex(RuntimeError, "signed out"):
                            remote_control.enable(socket_path)
                    else:
                        # Repeated checks must work on an already running server.
                        remote_control.enable(socket_path)
                        remote_control.enable(socket_path)
                finally:
                    server.shutdown()
                    worker.join(timeout=5)
        self.assertEqual(failures, [])
        for index in range(0, len(calls), 3):
            self.assertTrue(calls[index]["params"]["capabilities"]["experimentalApi"])
            self.assertEqual(calls[index + 1], {"method": "initialized"})
            self.assertEqual(calls[index + 2], {"id": 2, "method": "remoteControl/enable", "params": {"ephemeral": True}})

    def test_reenable_existing_server(self):
        self.exercise()

    def test_authentication_failure_is_reported(self):
        self.exercise(error=True)


if __name__ == "__main__":
    unittest.main()
