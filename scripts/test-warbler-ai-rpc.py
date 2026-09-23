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
nix --extra-experimental-features nix-command store ping --store daemon
for tool in git gh rustup mbx node npm bun uv pnpm vp python python3 pip; do command -v "$tool"; done
uv --version
pnpm --version
# Query the executable's directory layout without first-run network bootstrap.
VP_DUMP_DIRS=1 vp >/tmp/vp-dirs
test -s /tmp/vp-dirs
test "$(npm config get prefix)" = "$HOME/.npm-global"
python -c 'import sys; assert sys.prefix == "/home/cody-ai/.local/share/python-default"'
python -m pip --version
mkdir -p /tmp/npm-proof
printf '%s' '{"name":"ai-tool-proof","version":"1.0.0","bin":{"ai-tool-proof":"cli.js"}}' > /tmp/npm-proof/package.json
printf '%s\\n' '#!/usr/bin/env node' 'console.log("npm-ok")' > /tmp/npm-proof/cli.js
npm install -g --offline --ignore-scripts --no-audit --no-fund /tmp/npm-proof
ai-tool-proof | grep npm-ok
python - <<'WHEEL'
import zipfile
with zipfile.ZipFile('/tmp/ai_proof-1.0-py3-none-any.whl', 'w') as wheel:
    wheel.writestr('ai_proof.py', 'value = 42')
    wheel.writestr('ai_proof-1.0.dist-info/METADATA', 'Metadata-Version: 2.1\\nName: ai-proof\\nVersion: 1.0\\n')
    wheel.writestr('ai_proof-1.0.dist-info/WHEEL', 'Wheel-Version: 1.0\\nGenerator: test\\nRoot-Is-Purelib: true\\nTag: py3-none-any\\n')
    wheel.writestr('ai_proof-1.0.dist-info/RECORD', '')
WHEEL
pip install --no-index --no-deps /tmp/ai_proof-1.0-py3-none-any.whl
python -c 'import ai_proof; assert ai_proof.value == 42'
python -m venv /tmp/project-venv
/tmp/project-venv/bin/python -m pip --version
grep -q 'NoNewPrivs:[[:space:]]*1' /proc/self/status
printf persisted > /home/cody-ai/workspaces/proof
printf private > /tmp/ai-private-test
printf sandbox-ok
"""],
        "cwd": "/home/cody-ai/workspaces",
        "sandboxPolicy": {"type": "dangerFullAccess"},
        "timeoutMs": 60000,
    })
    assert result["exitCode"] == 0, result
    assert "sandbox-ok" in result["stdout"], result
    # Exercise the inner sandbox too: the outer service/container must permit
    # Bubblewrap's user/network namespaces and NETLINK_ROUTE loopback setup.
    for ident, policy in enumerate([
        {"type": "readOnly"},
        {"type": "workspaceWrite", "writableRoots": ["/home/cody-ai/workspaces"],
         "networkAccess": False},
    ], start=3):
        result = request(ident, "command/exec", {
            "command": ["python3", "-c", """
import errno
import pathlib
import tempfile

workspace = pathlib.Path('/home/cody-ai/workspaces')
try:
    with tempfile.TemporaryFile(dir=workspace) as proof:
        proof.write(b'inner-sandbox-proof')
except OSError as error:
    assert error.errno in (errno.EACCES, errno.EPERM, errno.EROFS), error
    assert EXPECT_READ_ONLY
else:
    assert not EXPECT_READ_ONLY
print('inner-sandbox-ok')
""".replace("EXPECT_READ_ONLY", repr(policy["type"] == "readOnly"))],
            "cwd": "/home/cody-ai/workspaces",
            "sandboxPolicy": policy,
            "timeoutMs": 10000,
        })
        assert result["exitCode"] == 0, result
        assert "inner-sandbox-ok" in result["stdout"], result
    proxy.stdin.close()
    proxy.wait(timeout=10)
    assert proxy.returncode == 0, proxy.returncode
