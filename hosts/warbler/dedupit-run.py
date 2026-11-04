"""Supervise one incremental run, retaining results and disk headroom."""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def save(path, value):
    temporary = path.with_suffix(path.suffix + ".new")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def stop(process):
    process.terminate()
    try:
        return process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        process.kill()
        return process.wait()


def run(command, directory, minimum_free_bytes, interval=30, free_bytes=None):
    os.umask(0o077)
    directory = Path(directory)
    free_bytes = free_bytes or (lambda: shutil.disk_usage(directory).free)
    status = {"started_at": now(), "command": command, "state": "running"}
    status_path = directory / "filesystem-status.json"
    result_path = directory / "filesystem-result.json"
    partial_path = directory / "filesystem-result.json.partial"
    interrupted = []
    handlers = {}
    process = None
    exit_code = 1
    try:
        for signum in (signal.SIGTERM, signal.SIGINT):
            handlers[signum] = signal.signal(signum, lambda n, _: interrupted.append(n))
        status["free_before"] = free_bytes()
        if status["free_before"] < minimum_free_bytes:
            status["state"] = "paused_for_space"
            exit_code = 75
        else:
            save(status_path, status)
            with partial_path.open("w") as output:
                process = subprocess.Popen(command, stdout=output)
                status["pid"] = process.pid
                save(status_path, status)
                next_check = 0
                while process.poll() is None:
                    if interrupted:
                        status["state"] = "interrupted"
                        stop(process)
                        exit_code = 128 + interrupted[0]
                        break
                    if time.monotonic() >= next_check:
                        status["free_now"] = free_bytes()
                        next_check = time.monotonic() + interval
                        if status["free_now"] < minimum_free_bytes:
                            status["state"] = "paused_for_space"
                            stop(process)
                            exit_code = 75
                            break
                    try:
                        process.wait(timeout=min(interval, 1))
                    except subprocess.TimeoutExpired:
                        continue
                else:
                    exit_code = 128 + interrupted[0] if interrupted else process.returncode
                    status["state"] = (
                        "interrupted" if interrupted else
                        "completed" if exit_code == 0 else
                        "finished_with_errors" if exit_code == 2 else "failed"
                    )
                status["child_exit_code"] = process.returncode
            if exit_code in (0, 2):
                # Preserve the last complete report if a later run is interrupted.
                result = json.loads(partial_path.read_text())
                status["errors"] = len(result["errors"])
                status["jobs_completed"] = result["jobs_completed"]
                status["bytes_deduped"] = result["bytes_deduped"]
                partial_path.replace(result_path)
    except Exception as error:
        status.update(state="failed", error=str(error))
        exit_code = 1
        if process is not None and process.poll() is None:
            stop(process)
    finally:
        for signum, handler in handlers.items():
            signal.signal(signum, handler)
    status.update(exit_code=exit_code, finished_at=now())
    save(status_path, status)
    print(json.dumps(status), flush=True)
    return exit_code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-directory", type=Path, required=True)
    parser.add_argument("--minimum-free-bytes", type=int, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a dedupit command is required")
    return run(command, args.state_directory, args.minimum_free_bytes)


if __name__ == "__main__":
    sys.exit(main())
