#!/usr/bin/env python3
"""Update versions and platform-specific hashes for tracked packages.

Packages are listed in nixpkgs/tracked-packages.json. Version and source-hash
updates use nix-update. Packages with a hashFile also have a fixed-output
subpackage rebuilt for the requested system, so the scheduled workflow can run
the hash phase on Linux and both Darwin runners.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "nixpkgs/tracked-packages.json"
FAKE_HASH = "sha256-" + "A" * 43 + "="


def run(command):
    return subprocess.run(
        command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def nix(*args):
    result = run(["nix", *args])
    sys.stderr.write(result.stderr)
    return result


def native_system():
    result = nix("eval", "--impure", "--raw", "--expr", "builtins.currentSystem")
    if result.returncode:
        raise RuntimeError("Cannot determine the native Nix system")
    return result.stdout


def platform_key(system):
    # The opencode expression shares one Linux fixed-output hash across
    # architectures and keeps separate hashes for each Darwin architecture.
    return "linux" if system.endswith("-linux") else system


def load_manifest():
    return json.loads(MANIFEST.read_text())


def manage_paths(package):
    paths = set()
    if "file" in package:
        paths.add(ROOT / package["file"])
    if "hashFile" in package:
        paths.add(ROOT / package["hashFile"])
    return paths


def snapshot(package):
    return {
        path: path.read_bytes()
        for path in manage_paths(package)
        if path.exists()
    }


def restore(files):
    for path, content in files.items():
        path.write_bytes(content)


def write_hashes(path, hashes):
    path.write_text(json.dumps(hashes, indent=2, sort_keys=True) + "\n")


def update_version(name, package):
    command = ["nix-update", "--flake"]
    if "hashFile" in package:
        # The fixed-output hash is maintained per platform below.
        command.append("--src-only")
    command.append(name)
    result = run(command)
    sys.stderr.write(result.stderr)
    if result.returncode:
        raise RuntimeError(f"nix-update failed for {name}")
    sys.stdout.write(result.stdout)


def hash_expression(name, package, system):
    flake = json.dumps("git+" + ROOT.as_uri())
    return (
        f'(builtins.getFlake {flake}).packages.{system}.{name}.'
        f'{package["hashAttribute"]}.overrideAttrs '
        f'(_: {{ outputHash = "{FAKE_HASH}"; }})'
    )


def discover_hash(name, package, system):
    expression = hash_expression(name, package, system)
    drv = nix("eval", "--impure", "--raw", "--expr", f"({expression}).drvPath")
    if drv.returncode:
        raise RuntimeError(f"Cannot evaluate {name}.{package['hashAttribute']} for {system}")
    result = nix(
        "build", "--impure", "--accept-flake-config", "--no-update-lock-file",
        "--no-link", "--print-build-logs", "--expr", expression,
    )
    # Only accept the mismatch for the exact derivation we requested. Network,
    # evaluation, and dependency failures must abort the update.
    match = re.search(
        r"hash mismatch in fixed-output derivation ['\"]" + re.escape(drv.stdout)
        + r"['\"]:\s+(?:likely URL:[^\n]*\n\s+)?specified:\s+" + re.escape(FAKE_HASH)
        + r"\s+got:\s+(sha256-[A-Za-z0-9+/]{43}=)",
        result.stderr,
    )
    if result.returncode == 0 or match is None:
        raise RuntimeError(
            f"Expected a hash mismatch for {name}.{package['hashAttribute']} on {system}"
        )
    return match[1]


def verify_hash(name, package, system):
    result = nix(
        "build", "--accept-flake-config", "--no-update-lock-file", "--no-link",
        f".#packages.{system}.{name}.{package['hashAttribute']}",
    )
    if result.returncode:
        raise RuntimeError(
            f"Verification failed for {name}.{package['hashAttribute']} on {system}"
        )


def package_version(name, system):
    result = nix(
        "eval", "--impure", "--raw", "--expr",
        f'(builtins.getFlake {json.dumps("git+" + ROOT.as_uri())})'
        f'.packages.{system}.{name}.version',
    )
    if result.returncode:
        raise RuntimeError(f"Cannot evaluate the version of {name} for {system}")
    return result.stdout


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--system",
        help="Nix system whose hashes to refresh (default: the native system)",
    )
    parser.add_argument(
        "--update-versions",
        action="store_true",
        help="Run nix-update for every tracked package first (Linux only)",
    )
    parser.add_argument(
        "--no-verify",
        action="store_true",
        help="Skip the post-update fixed-output build",
    )
    parser.add_argument(
        "--mark-version",
        action="store_true",
        help="Record the current package version after the last platform succeeds",
    )
    args = parser.parse_args(argv)

    system = args.system or native_system()
    manifest = load_manifest()
    if args.update_versions and not system.endswith("-linux"):
        raise RuntimeError("Run --update-versions on Linux, as in the flake-update workflow")

    key = platform_key(system)
    failures = []

    for name, package in manifest.items():
        original = snapshot(package)
        try:
            if args.update_versions:
                update_version(name, package)

            if "hashFile" in package:
                hash_file = ROOT / package["hashFile"]
                hashes = json.loads(hash_file.read_text())
                if key not in hashes:
                    # Seed a placeholder so the expression can evaluate while
                    # the first hash for this platform is discovered.
                    hashes[key] = FAKE_HASH
                    write_hashes(hash_file, hashes)
                hashes[key] = discover_hash(name, package, system)
                write_hashes(hash_file, hashes)

                if not args.no_verify:
                    verify_hash(name, package, system)

                if args.mark_version:
                    hashes["version"] = package_version(name, system)
                    write_hashes(hash_file, hashes)
        except Exception as error:
            # Keep a bad upstream release from blocking other tracked packages.
            restore(original)
            failures.append(f"{name}: {error}")

    if failures:
        raise RuntimeError("; ".join(failures))


if __name__ == "__main__":
    main()
