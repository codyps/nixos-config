"""Explicit, hash-pinned deployment; never restart or reload Hindsight.

check is read-only. apply/restore only recognize the two exact source revisions.
An upgrade or any other local change requires manual review, not a blind overwrite.
"""
import argparse
import hashlib
from pathlib import Path

ORIGINAL_SHA256 = "59e54319b2dcbf38606c03e38e8fff684a3d2f9cb05d01f211aca399f5b65f88"
PATCHED_SHA256 = "0351157c5cf24c7f69aff19f5c5bc3bd1868c432700c83d94212817d65965d85"
ROOT = Path(__file__).resolve().parent
DEFAULT_TARGET = Path("M:/Hindsight/.venv/Lib/site-packages/hindsight_api/engine/reflect/delta_ops.py")

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("action", choices=("check", "apply", "restore"))
parser.add_argument("--target", type=Path, default=DEFAULT_TARGET,
                    help="Explicit alternative target (primarily for offline safety tests)")
args = parser.parse_args()

sources = {}
for state, filename, expected_hash in (
    ("original", "delta_ops.original.py", ORIGINAL_SHA256),
    ("patched", "delta_ops.patched.py", PATCHED_SHA256),
):
    try:
        data = (ROOT / filename).read_bytes()
    except OSError as exc:
        parser.exit(2, f"Refusing: cannot read {filename}: {exc}\n")
    if hashlib.sha256(data).hexdigest() != expected_hash:
        parser.exit(2, f"Refusing: {filename} does not match its pinned SHA256\n")
    sources[state] = data

try:
    current = args.target.read_bytes()
except OSError as exc:
    parser.exit(2, f"Refusing: cannot read target: {exc}\n")
current_hash = hashlib.sha256(current).hexdigest()
if current_hash == ORIGINAL_SHA256:
    state = "original"
elif current_hash == PATCHED_SHA256:
    state = "patched"
else:
    parser.exit(2, f"Refusing: changed upstream/unknown target SHA256 {current_hash}; review manually\n")

if args.action != "check":
    desired_state = "patched" if args.action == "apply" else "original"
    if state != desired_state:
        args.target.write_bytes(sources[desired_state])
        state = desired_state
    if args.target.read_bytes() != sources[desired_state]:
        parser.exit(2, "Deployment verification failed: target differs from selected pinned source\n")
    current_hash = hashlib.sha256(sources[desired_state]).hexdigest()

print(f"{state}: {args.target}\nSHA256 {current_hash}")
print("No services restarted or reloaded.")
