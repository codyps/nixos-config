#!/usr/bin/env python3
"""Build and provision the stopped container; preserve existing keys and store."""
import argparse
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path,
                        default=Path.home() / ".local/state/nix-docker-builder")
    parser.add_argument("--context", default="orbstack")
    args = parser.parse_args()
    state = args.state_dir.resolve()
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(state, 0o700)
    docker = ["docker", "--context", args.context]

    def run(*cmd, **kwargs):
        return subprocess.run(cmd, check=True, text=True, **kwargs)

    if not (state / "id_ed25519").exists():
        run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "nix-docker-builder",
            "-f", str(state / "id_ed25519"))
    run(*docker, "build", "-t", "nix-linux-builder:local", str(Path(__file__).parent))
    for volume in ("nix-linux-builder-store", "nix-linux-builder-keys"):
        run(*docker, "volume", "create", volume, stdout=subprocess.DEVNULL)
    # Copy only the PUBLIC client key. No host directories or Docker socket are
    # mounted into the actual builder, and its private host key stays in Docker.
    run(*docker, "run", "--rm", "--network", "none", "-v",
        f"{state / 'id_ed25519.pub'}:/client.pub:ro", "-v",
        "nix-linux-builder-keys:/builder-keys", "nix-linux-builder:local", "sh", "-ec",
        'cp /client.pub /builder-keys/authorized_keys; '
        'chmod 600 /builder-keys/authorized_keys; '
        'test -f /builder-keys/ssh_host_ed25519_key || '
        'ssh-keygen -q -t ed25519 -N "" -f /builder-keys/ssh_host_ed25519_key')
    pub = run(*docker, "run", "--rm", "--network", "none", "-v",
              "nix-linux-builder-keys:/builder-keys:ro", "nix-linux-builder:local",
              "cat", "/builder-keys/ssh_host_ed25519_key.pub",
              stdout=subprocess.PIPE).stdout.split()
    (state / "known_hosts").write_text(f"docker-linux-builder {pub[0]} {pub[1]}\n")
    found = subprocess.run([*docker, "container", "inspect", "nix-linux-builder"],
                           text=True, capture_output=True)
    if found.returncode == 0:
        info = json.loads(found.stdout)[0]
        image = run(*docker, "image", "inspect", "--format", "{{.Id}}",
                    "nix-linux-builder:local", stdout=subprocess.PIPE).stdout.strip()
        if ((info["Config"]["Labels"] or {}).get("org.nixos.ssh-activation") != "true"
                or info["Image"] != image):
            raise SystemExit("Existing container differs; stop/remove it explicitly, then rerun. "
                             "Keep the named volumes to preserve the store and keys.")
    else:
        run(*docker, "create", "--name", "nix-linux-builder",
            "--label", "org.nixos.ssh-activation=true", "--restart", "no",
            "--cpus", "4", "--memory", "4g", "--pids-limit", "2048",
            "-p", "127.0.0.1:31024:22",
            "-v", "nix-linux-builder-store:/nix",
            "-v", "nix-linux-builder-keys:/builder-keys:ro",
            "nix-linux-builder:local")
    print(f"Builder provisioned. Client key and pinned known_hosts: {state}")


if __name__ == "__main__":
    main()
