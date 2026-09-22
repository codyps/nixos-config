"""Check the container's actual Codex task environment without model credentials."""
import json
from websockets.sync.client import unix_connect

with unix_connect(
    "/home/cody-ai/.codex/app-server-control/app-server-control.sock",
    compression=None,
    max_size=None,
) as websocket:
    def request(ident, method, params):
        websocket.send(json.dumps({"id": ident, "method": method, "params": params}))
        while True:
            response = json.loads(websocket.recv(timeout=90))
            if response.get("id") == ident:
                assert "error" not in response, response
                return response["result"]

    request(1, "initialize", {"clientInfo": {"name": "container-test", "version": "1"}})
    websocket.send('{"method":"initialized"}')
    result = request(2, "command/exec", {
        "command": ["/bin/bash", "-lc", """
set -eux
test "$(id -un)" = cody-ai
test "$(hostname)" = warbler-ai
test ! -e /persist/host-only
test ! -e /home/cody-ai/host-only
test -S /run/user/1001/bus
systemctl --user is-active codex-ai
systemd-run --user --wait --pipe /bin/bash -c 'echo gateway-service-ok'
command -v git uv pip node
touch ~/workspaces/codex-proof
"""],
        "cwd": "/home/cody-ai/workspaces",
        "sandboxPolicy": {"type": "dangerFullAccess"},
        "timeoutMs": 60000,
    })
    assert result["exitCode"] == 0, result
    assert "gateway-service-ok" in result["stdout"], result
