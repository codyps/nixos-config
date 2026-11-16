"""Local root-only GARM administration without secrets in command arguments."""
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time
import tomllib
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen

BASE = "http://127.0.0.1:9997"
GITHUB_API = "https://api.github.com"


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


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def github(method, path, token, scheme="token"):
    req = Request(GITHUB_API + path, method=method, headers={
        "Accept": "application/vnd.github+json",
        "Authorization": f"{scheme} {token}",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    with urlopen(req, timeout=30) as response:
        return json.loads(response.read())


def installation_repositories(env):
    """Return {(owner, name)} for every unarchived repository granted to the App."""
    now = int(time.time())
    header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    claims = b64url(json.dumps({"iat": now - 60, "exp": now + 540, "iss": env["GARM_SYNC_APP_ID"]}).encode())
    signature = subprocess.run(
        [env["GARM_SYNC_OPENSSL"], "dgst", "-sha256", "-sign", env["GARM_SYNC_APP_KEY"]],
        input=f"{header}.{claims}".encode(), capture_output=True, check=True).stdout
    jwt = f"{header}.{claims}.{b64url(signature)}"
    installation = env["GARM_SYNC_INSTALLATION_ID"]
    token = github("POST", f"/app/installations/{installation}/access_tokens", jwt, "Bearer")["token"]
    repos, page = [], 1
    while True:
        result = github("GET", f"/installation/repositories?per_page=100&page={page}", token)
        total = result["total_count"]
        repos.extend(result["repositories"])
        if not result["repositories"] or len(repos) >= total:
            break
        page += 1
    if len(repos) != total:
        raise SystemExit(f"Incomplete installation listing: {len(repos)} of {total}")
    return {(r["owner"]["login"], r["name"]) for r in repos if not r["archived"]}


def sync_repos(token):
    """Register every App-visible repository and its scale set; never deletes."""
    env = os.environ
    credentials = env["GARM_SYNC_CREDENTIALS"]
    scale_set = json.loads(env["GARM_SYNC_SCALE_SET"])
    wanted = installation_repositories(env)

    def key(owner, name):
        return owner.lower(), name.lower()

    wanted_keys = {key(*repo) for repo in wanted}
    garm_repos = {key(r["owner"], r["name"]): r for r in request("GET", "/repositories", token=token) or []}
    with_scale_set = {s["repo_id"] for s in request("GET", "/scalesets", token=token) or []
                      if s.get("repo_id") and s["name"] == scale_set["name"]}
    added_repos = added_sets = failed = 0
    for owner, name in sorted(wanted, key=lambda repo: key(*repo)):
        try:
            repo = garm_repos.get(key(owner, name))
            if repo is None:
                repo = request("POST", "/repositories", {
                    "owner": owner, "name": name, "credentials_name": credentials,
                    "webhook_secret": secrets.token_urlsafe(32),
                    "pool_balancer_type": "roundrobin", "forge_type": "github",
                }, token)
                added_repos += 1
                print(f"registered {owner}/{name}", flush=True)
            if repo["id"] not in with_scale_set:
                request("POST", f"/repositories/{quote(repo['id'])}/scalesets", scale_set, token)
                with_scale_set.add(repo["id"])
                added_sets += 1
                print(f"created scale set {scale_set['name']} for {owner}/{name}", flush=True)
        except HTTPError as error:
            failed += 1
            detail = error.read().decode(errors="replace")[:300]
            print(f"failed {owner}/{name}: HTTP {error.code} {detail}", file=sys.stderr, flush=True)
    for k, repo in sorted(garm_repos.items()):
        if repo.get("credentials_name") == credentials and k not in wanted_keys:
            print(f"warning: {repo['owner']}/{repo['name']} is registered but no longer "
                  "granted to the App (not removed)", flush=True)
    print(f"{len(wanted)} repositories granted; registered {added_repos}, "
          f"created {added_sets} scale sets, {failed} failures", flush=True)
    if failed:
        raise SystemExit(1)


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
    if args == ["sync-repos"]:
        sync_repos(token)
        return
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
