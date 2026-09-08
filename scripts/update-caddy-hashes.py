#!/usr/bin/env python3
"""On Linux, recompute both Caddy plugin source hashes and verify them."""

import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
HASHES = ROOT / "nixpkgs/caddy-hashes.json"
FAKE_HASH = "sha256-" + "A" * 43 + "="
SOURCES = {"nixpkgs": "caddy-source", "nixpkgs-darwin": "caddy-darwin-source"}


def nix(*args):
    result = subprocess.run(
        ["nix", *args], cwd=ROOT, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    sys.stderr.write(result.stderr)
    return result


def main():
    system = nix("eval", "--impure", "--raw", "--expr", "builtins.currentSystem")
    if system.returncode:
        raise RuntimeError("Cannot determine the native Nix system")
    if not system.stdout.endswith("-linux"):
        raise RuntimeError("Run the hash updater on Linux, as in the flake-update workflow")
    # A path flake includes newly created files during local development too.
    flake = "path:" + str(ROOT)
    hashes = json.loads(HASHES.read_text())
    for key, package in SOURCES.items():
        expression = (
            f'(builtins.getFlake {json.dumps(flake)}).packages.'
            f'{system.stdout}.{package}.overrideAttrs (_: '
            f'{{ outputHash = "{FAKE_HASH}"; }})'
        )
        drv = nix("eval", "--impure", "--raw", "--expr", f"({expression}).drvPath")
        if drv.returncode:
            raise RuntimeError(f"Cannot evaluate {package}")
        result = nix(
            "build", "--impure", "--accept-flake-config", "--no-update-lock-file",
            "--no-link", "--print-build-logs", "--expr", expression,
        )
        # Only accept the mismatch for the exact source derivation we requested.
        # Network, evaluation, and dependency failures must abort the update.
        match = re.search(
            r"hash mismatch in fixed-output derivation ['\"]" + re.escape(drv.stdout)
            + r"['\"]:\s+(?:likely URL:[^\n]*\n\s+)?specified:\s+" + re.escape(FAKE_HASH)
            + r"\s+got:\s+(sha256-[A-Za-z0-9+/]{43}=)",
            result.stderr,
        )
        if result.returncode == 0 or match is None:
            raise RuntimeError(f"Expected a source hash mismatch for {package}")
        hashes[key] = match[1]

    original = HASHES.read_bytes()
    try:
        HASHES.write_text(json.dumps(hashes, indent=2) + "\n")
        for package in SOURCES.values():
            result = nix(
                "build", "--accept-flake-config", "--no-update-lock-file", "--no-link",
                "--print-build-logs", f"{flake}#packages.{system.stdout}.{package}",
            )
            if result.returncode:
                raise RuntimeError(f"Verification failed for {package}")
    except BaseException:
        HASHES.write_bytes(original)
        raise


if __name__ == "__main__":
    main()
