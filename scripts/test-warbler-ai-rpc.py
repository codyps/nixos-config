"""Exercise the real SSH-facing Codex transport without model credentials."""
import json
import subprocess

with subprocess.Popen(
    ["codex", "app-server", "--analytics-default-enabled"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    text=True,
) as proxy:
    def request(ident, method, params):
        proxy.stdin.write(json.dumps({"id": ident, "method": method, "params": params}) + "\n")
        proxy.stdin.flush()
        for line in proxy.stdout:
            response = json.loads(line)
            if response.get("id") == ident:
                assert "error" not in response, response
                return response["result"]
        raise AssertionError("proxy exited before responding")

    request(1, "initialize", {"clientInfo": {"name": "warbler-test", "version": "1"}})
    proxy.stdin.write('{"method":"initialized"}\n')
    proxy.stdin.flush()
    result = request(2, "command/exec", {
        "command": ["bash", "-c", """
set -eux
test "$(id -un)" = cody-ai
test "$(id -Gn)" = cody-ai
test ! -r /home/cody/private-test
test ! -r /persist/public-test
test ! -r /run/secrets/public-test
test ! -r /root/private-test
test ! -e /dev/sda
! touch /etc/ai-test
! touch /var/lib/ai-test
! test -S /nix/var/nix/daemon-socket/socket
grep -q 'NoNewPrivs:[[:space:]]*1' /proc/self/status
printf persisted > /home/cody-ai/workspaces/proof
printf private > /tmp/ai-private-test
printf sandbox-ok
"""],
        "cwd": "/home/cody-ai/workspaces",
        "sandboxPolicy": {"type": "dangerFullAccess"},
        "timeoutMs": 10000,
    })
    assert result["exitCode"] == 0, result
    assert "sandbox-ok" in result["stdout"], result
    proxy.stdin.close()
    proxy.wait(timeout=10)
    assert proxy.returncode == 0, proxy.returncode
