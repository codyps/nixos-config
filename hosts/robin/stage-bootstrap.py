#!/usr/bin/env python3
"""Restore Robin's encrypted bootstrap identities into a NEW external staging dir."""
import json
import os
from pathlib import Path
import subprocess
import sys

repo = Path(__file__).resolve().parents[2]
if len(sys.argv) != 2:
    raise SystemExit("Usage: python3 hosts/robin/stage-bootstrap.py /external/new-staging-dir")
target = Path(sys.argv[1]).resolve()
if target == repo or repo in target.parents:
    raise SystemExit("Keep plaintext staging outside the repository and Nix store")
if target == Path("/nix/store") or Path("/nix/store") in target.parents:
    raise SystemExit("Keep plaintext staging outside the Nix store")
os.umask(0o077)
material = json.loads(subprocess.run(
    ["sops", "decrypt", "--output-type", "json", str(repo / "secrets/robin-bootstrap.yaml")],
    text=True, capture_output=True, check=True,
).stdout)
target.mkdir(mode=0o700)  # Refuse to overwrite an existing staging directory.
ssh = target / "extra-files/persist/ssh"
ssh.mkdir(parents=True, mode=0o700)
for name in ("ssh_host_ed25519_key", "initrd_ssh_host_ed25519_key"):
    for suffix in ("", ".pub"):
        (ssh / (name + suffix)).write_text(material[name + suffix])
print(f"Staged identities under {target / 'extra-files'}. Remove staging after installation.")
