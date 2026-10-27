"""Re-enable remote control on the systemd-owned server without starting a daemon."""
import json
import sys
import time

from websockets.sync.client import unix_connect


def request(websocket, request_id, method, params):
    websocket.send(json.dumps({"id": request_id, "method": method, "params": params}))
    deadline = time.monotonic() + 20
    while True:
        message = json.loads(websocket.recv(timeout=max(0, deadline - time.monotonic())))
        if message.get("id") != request_id:
            continue
        if "error" in message:
            raise RuntimeError(f"{method}: {message['error']}")
        return message["result"]


def enable(socket_path):
    # Use the same client identity as Codex's native remote-control command.
    # ephemeral=true matches that command and avoids changing account preferences.
    with unix_connect(socket_path, compression=None, open_timeout=10, close_timeout=2) as websocket:
        request(websocket, 1, "initialize", {
            "clientInfo": {"name": "codex_app_server_daemon", "version": "0.1.0"},
            "capabilities": {"experimentalApi": True},
        })
        websocket.send(json.dumps({"method": "initialized"}))
        request(websocket, 2, "remoteControl/enable", {"ephemeral": True})


if __name__ == "__main__":
    enable(sys.argv[1])
