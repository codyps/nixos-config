#!/usr/bin/env python3
"""Build one configuration; retain measurements even when Nix fails."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time


def main(target):
    report = Path("pilot")
    report.mkdir(exist_ok=True)
    started = time.monotonic()
    initial_free = shutil.disk_usage("/nix/store").free
    minimum_free = initial_free
    metrics = {
        "target": target,
        "revision": os.environ.get("GITHUB_SHA"),
        "initial_free_bytes": initial_free,
    }
    try:
        # Inherit output so GitHub streams Nix's build logs as they happen.
        with subprocess.Popen([
            "nix", "build", "--accept-flake-config", "--no-update-lock-file",
            "--print-build-logs", "--out-link", "result", target,
        ]) as process:
            while True:
                minimum_free = min(minimum_free, shutil.disk_usage("/nix/store").free)
                try:
                    metrics["build_exit_code"] = process.wait(timeout=2)
                    break
                except subprocess.TimeoutExpired:
                    pass
        metrics["build_seconds"] = round(time.monotonic() - started, 2)
        minimum_free = min(minimum_free, shutil.disk_usage("/nix/store").free)
        if metrics["build_exit_code"] != 0:
            return metrics["build_exit_code"]

        result = subprocess.run([
            "nix", "path-info", "--json", "--closure-size", "./result",
        ], check=True, capture_output=True, text=True)
        closure = json.loads(result.stdout)
        (report / "closure.json").write_text(json.dumps(closure, indent=2) + "\n")
        # Nix versions use either a list or a store-path-keyed object.
        roots = closure.values() if isinstance(closure, dict) else closure
        metrics["closure_bytes"] = sum(root["closureSize"] for root in roots)
        return 0
    finally:
        metrics["elapsed_seconds"] = round(time.monotonic() - started, 2)
        metrics["minimum_sampled_free_bytes"] = minimum_free
        metrics["peak_sampled_disk_growth_bytes"] = initial_free - minimum_free
        (report / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a") as output:
                output.write(f"### {target}\n\n```json\n")
                output.write(json.dumps(metrics, indent=2) + "\n```\n")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
