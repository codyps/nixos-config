"""Installer package and bounded Recovery-to-published-image orchestration."""

import csv
import fcntl
import io
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def public_key(text):
    fields = text.strip().split()
    if len(fields) < 2 or fields[0] not in ("ssh-ed25519", "ssh-rsa"):
        raise ValueError("use a plain Ed25519 or RSA SSH public key")
    return " ".join(fields[:2])


def package(image, args):
    destination = image.safe_path(args.output)
    if destination.exists() or destination.with_suffix(".json").exists():
        raise ValueError("bootstrap output already exists")
    key = public_key(Path(args.public_key).read_text())
    image.run("ssh-keygen", "-lf", args.public_key, stdout=subprocess.DEVNULL)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        payload = root / "payload"
        script = payload / "usr/local/libexec/actions-vm-image-firstboot"
        script.parent.mkdir(parents=True)
        shutil.copyfile(image.GUEST / "firstboot.sh", script)
        script.chmod(0o755)
        pubkey = payload / "usr/local/share/actions-vm-image/builder.pub"
        pubkey.parent.mkdir(parents=True)
        pubkey.write_text(key + "\n")
        daemon = payload / "Library/LaunchDaemons/org.actions-vm.image-firstboot.plist"
        daemon.parent.mkdir(parents=True)
        daemon.write_bytes(
            plistlib.dumps(
                {
                    "Label": "org.actions-vm.image-firstboot",
                    "ProgramArguments": [
                        "/usr/local/libexec/actions-vm-image-firstboot"
                    ],
                    "RunAtLoad": True,
                    "KeepAlive": {"SuccessfulExit": False},
                    "ThrottleInterval": 10,
                    "StandardOutPath": "/var/log/actions-vm-image-firstboot.log",
                    "StandardErrorPath": "/var/log/actions-vm-image-firstboot.log",
                }
            )
        )
        scripts = root / "scripts"
        scripts.mkdir()
        shutil.copyfile(image.GUEST / "postinstall", scripts / "postinstall")
        (scripts / "postinstall").chmod(0o755)
        # main() uses umask 077; installer payload directories must be traversable.
        payload.chmod(0o755)
        for path in payload.rglob("*"):
            path.chmod(0o755 if path.is_dir() or path == script else 0o644)
        image.run(
            "/usr/bin/pkgbuild",
            "--root",
            payload,
            "--scripts",
            scripts,
            "--identifier",
            "org.actions-vm.image-firstboot",
            "--version",
            "1.0",
            "--ownership",
            "recommended",
            root / "component.pkg",
        )
        image.run(
            "/usr/bin/productbuild", "--package", root / "component.pkg", destination
        )
    image.write_json(
        destination.with_suffix(".json"),
        {
            "sha256": image.digest(destination),
            "public_key": key,
        },
    )
    print(
        f"Created {destination} and its key/hash manifest; copy both to the KVM host."
    )


def words(image, work):
    with image.QMP(work) as qmp:
        qmp.call("screendump", {"filename": str(work / "screen.ppm")})
    result = image.run(
        "tesseract",
        work / "screen.ppm",
        "stdout",
        "--psm",
        "11",
        "tsv",
        capture_output=True,
        text=True,
    )
    return [
        row
        for row in csv.DictReader(io.StringIO(result.stdout), delimiter="\t")
        if row.get("text", "").strip()
    ]


def screen_action(rows, requested):
    """Return only actions supported by observed text; never guess on an unknown screen."""
    text = " ".join(row["text"] for row in rows).lower()
    if "terminal" in text and "bash" in text:
        return ("install", None) if not requested else (None, None)
    if (
        "disk utility" in text or "restore from time machine" in text
    ) and "reinstall" in text:
        return ("terminal", None) if not requested else (None, None)
    # Boot picker has volume labels but none of the Recovery application's prose.
    if len(rows) < 25 and not any(
        word in text for word in ("reinstall", "disk utility", "terminal", "bash")
    ):
        macos = [r for r in rows if r["text"] == "MACOS"]
        installer = [r for r in rows if r["text"].lower() == "installer"]
        if requested and installer:
            return "boot", installer[0]
        if requested and macos:
            return "boot", macos[0]
    if "language" in text and "english" in text and not requested:
        return "english", next(r for r in rows if r["text"].lower() == "english")
    return None, None


def click(image, work, row):
    # QMP screendump is PPM P6. Dimensions come from the actual observed frame.
    with (work / "screen.ppm").open("rb") as stream:
        assert stream.readline().strip() == b"P6"
        width, height = map(int, stream.readline().split())
    x = int(row["left"]) + int(row["width"]) // 2
    y = int(row["top"]) + int(row["height"]) // 2
    with image.QMP(work) as qmp:
        qmp.call(
            "input-send-event",
            {
                "events": [
                    {"type": "abs", "data": {"axis": "x", "value": x * 32767 // width}},
                    {
                        "type": "abs",
                        "data": {"axis": "y", "value": y * 32767 // height},
                    },
                    {"type": "btn", "data": {"down": True, "button": "left"}},
                ]
            },
        )
        time.sleep(0.1)
        qmp.call(
            "input-send-event",
            {
                "events": [
                    {"type": "btn", "data": {"down": False, "button": "left"}},
                ]
            },
        )
        image.key(qmp, "ret")


def build(image, args):
    work = args.work_dir
    image.safe_path(args.destination)
    if args.timeout < 60:
        raise ValueError("installation timeout must be at least 60 seconds")
    if image.digest(Path(args.runner_archive)) != args.runner_sha256:
        raise ValueError("runner archive SHA256 mismatch")
    bootstrap = image.safe_path(args.bootstrap_package)
    metadata = json.loads(bootstrap.with_suffix(".json").read_text())
    if image.digest(bootstrap) != metadata["sha256"]:
        raise ValueError("bootstrap package SHA256 mismatch")
    actual_key = image.run(
        "ssh-keygen",
        "-y",
        "-P",
        "",
        "-f",
        args.identity,
        capture_output=True,
        text=True,
    ).stdout
    if public_key(actual_key) != metadata["public_key"]:
        raise ValueError("bootstrap package does not match provisioning identity")
    if Path(args.destination).exists():
        raise ValueError("publication destination already exists")
    with image.locked(work):
        if not (work / "image.json").exists():
            image.prepare(work, args)
        manifest = json.loads((work / "image.json").read_text())
        if manifest.get("sealed"):
            raise ValueError(
                "workspace is already sealed; publish it or use a fresh workspace"
            )
        previous = manifest.get("bootstrap_sha256")
        if previous and previous != metadata["sha256"]:
            raise ValueError("bootstrap package changed; use a fresh workspace")
        manifest["bootstrap_sha256"] = metadata["sha256"]
        image.write_json(work / "image.json", manifest)
        shutil.copyfile(bootstrap, work / "bootstrap.pkg")
        image.download(work, manifest)
    log = (work / "build-vm.log").open("ab")
    child = subprocess.Popen(
        [
            sys.executable,
            str(image.HERE / "image.py"),
            "--work-dir",
            str(work),
            "run",
            *(
                []
                if manifest.get("installed") or manifest.get("provisioned")
                else ["--installer"]
            ),
            "--ssh-port",
            str(args.ssh_port),
            "--vnc-display",
            str(args.vnc_display),
        ],
        stdout=log,
        stderr=log,
        preexec_fn=image.child_setup,  # noqa: PLW1509 - single-threaded CLI
    )
    try:
        deadline = time.monotonic() + args.timeout
        last_action = None
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise RuntimeError(f"QEMU exited; inspect {work}/build-vm.log")
            if not (work / "boot.json").exists() or not (work / "qmp.sock").exists():
                time.sleep(2)
                continue
            try:
                image.ssh(
                    work,
                    args,
                    "test -f /var/db/actions-vm-bootstrap-ready",
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=8,
                )
                print("First-boot SSH bootstrap is ready.", flush=True)
                break
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                pass
            rows = words(image, work)
            image.write_json(work / "screen-words.json", rows)
            requested = (work / "install-requested").exists()
            action, row = screen_action(rows, requested)
            if action and action != last_action:
                print(f"Observed console state: {action}", flush=True)
                if action in ("boot", "english"):
                    click(image, work, row)
                elif action == "terminal":
                    with image.QMP(work) as qmp:
                        image.key(qmp, "shift-meta_l-t")
                elif action == "install":
                    with (work / "install-requested").open("x") as marker:
                        marker.write("Automated Recovery install requested\n")
                    with image.QMP(work) as qmp:
                        image.type_text(
                            qmp, "/bin/bash /Volumes/IMAGE_BUILD/install.sh\n"
                        )
                last_action = action
            elif not action:
                last_action = None
            time.sleep(5)
        else:
            raise RuntimeError(
                f"installation timed out; inspect {work}/screen.ppm and logs"
            )
        manifest = json.loads((work / "image.json").read_text())
        manifest["installed"] = True
        image.write_json(work / "image.json", manifest)
        args.install_clt, args.toolchain, args.toolchain_sha256 = True, None, None
        with (work / ".provision-lock").open("a") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            image.provision(work, manifest, args)
            args.require_xcode, args.builder_password_file = False, None
            image.seal(work, manifest, args)
        child.wait(timeout=30)
        with image.locked(work):
            image.publish(work, manifest, args)
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=20)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        log.close()
