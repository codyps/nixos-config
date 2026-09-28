"""Local root-only GARM administration without secrets in command arguments."""
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tomllib
from urllib.error import HTTPError
from urllib.request import Request, urlopen

BASE = "http://127.0.0.1:9997"


def request(method, path, data=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = Request(BASE + "/api/v1" + path,
                  data=json.dumps(data).encode() if data is not None else None,
                  headers=headers, method=method)
    with urlopen(req, timeout=30) as response:
        body = response.read()
        return json.loads(body) if body else None


def main():
    if os.geteuid() != 0:
        raise SystemExit("Run with sudo: sudo sys garm COMMAND")
    os.umask(0o077)
    password_path = Path("/var/lib/garm/admin-password")
    args = sys.argv[2:]
    if args == ["bootstrap"]:
        if not password_path.exists():
            with password_path.open("x") as stream:
                stream.write(secrets.token_urlsafe(32))
        credentials = {"username": "admin", "password": password_path.read_text()}
        try:
            token = request("POST", "/auth/login", credentials)["token"]
        except HTTPError as error:
            if error.code not in (401, 403, 409):
                raise
            request("POST", "/first-run", dict(credentials, email="admin@warbler.local", full_name="Warbler administrator"))
            token = request("POST", "/auth/login", credentials)["token"]
        guest_url = "http://10.77.0.1:9998"
        request("PUT", "/controller", {
            "metadata_url": guest_url + "/api/v1/metadata",
            "callback_url": guest_url + "/api/v1/callbacks",
            "agent_url": guest_url + "/agent",
            "webhook_url": BASE + "/webhooks",
        }, token)
        print("GARM initialized. Admin password is in /var/lib/garm/admin-password (root only).")
        return
    if not password_path.exists():
        raise SystemExit("Initialize first: sudo sys garm bootstrap")
    token = request("POST", "/auth/login", {
        "username": "admin", "password": password_path.read_text()
    })["token"]
    # Upstream uses ~/.local/share, not XDG_CONFIG_HOME. Preserve other profiles.
    folder = Path.home() / ".local/share/garm-cli"
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    profile = folder / "config.toml"
    data = tomllib.loads(profile.read_text()) if profile.exists() else {}
    managers = [m for m in data.get("manager", []) if m["name"] != "warbler"]
    managers.append({"name": "warbler", "base_url": BASE, "bearer_token": token})
    lines = ['active_manager = "warbler"']
    for manager in managers:
        lines.append("[[manager]]")
        lines.extend(f"{key} = {json.dumps(value)}" for key, value in manager.items())
    profile.write_text("\n".join(lines) + "\n")
    profile.chmod(0o600)
    result = subprocess.run([sys.argv[1], *args])
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
