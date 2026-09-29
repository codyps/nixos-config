#!/usr/bin/env python3
"""Build and publish macOS disks for actions-vm-scaler. Run on the KVM host."""

import argparse
import contextlib
import ctypes
import fcntl
import hashlib
import json
import os
import plistlib
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

UPSTREAM = "https://github.com/kholia/OSX-KVM.git"
REVISION = "4c378a4b5e0b219783683012bec680325eb40719"
HERE = Path(__file__).resolve().parent
GUEST = HERE / "guest"
SCALER_GUEST = Path(
    os.environ.get(
        "ACTIONS_VM_SCALER_GUEST", str(HERE.parent / "actions-vm-scaler/guest")
    )
)


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def digest(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def safe_path(value):
    path = Path(value).absolute()
    if any(c in str(path) for c in ",\n\r"):
        raise ValueError("QEMU paths must not contain commas or newlines")
    return path


@contextlib.contextmanager
def locked(work):
    work.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (work / ".lock").open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("workspace is in use (possibly by a running VM)") from None
        yield


class QMP:
    def __init__(self, work):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(15)
        self.sock.connect(str(work / "qmp.sock"))
        self.stream = self.sock.makefile("rwb")
        self.stream.readline()
        self.call("qmp_capabilities")

    def call(self, execute, arguments=None):
        self.stream.write(
            (
                json.dumps({"execute": execute, "arguments": arguments or {}}) + "\n"
            ).encode()
        )
        self.stream.flush()
        while True:
            line = self.stream.readline()
            if not line:
                raise RuntimeError("QEMU disconnected")
            response = json.loads(line)
            if "error" in response:
                raise RuntimeError(str(response["error"]))
            if "return" in response:
                return response["return"]

    def close(self):
        self.stream.close()
        self.sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def key(qmp, name):
    qmp.call(
        "send-key",
        {
            "keys": [{"type": "qcode", "data": k} for k in name.split("-")],
            "hold-time": 50,
        },
    )
    # Setup Assistant can drop rapid USB key events, especially password fields.
    time.sleep(0.4)


def type_text(qmp, text):
    plain = dict(
        zip(
            " \n-=[]\\;',./`",
            [
                "spc",
                "ret",
                "minus",
                "equal",
                "bracket_left",
                "bracket_right",
                "backslash",
                "semicolon",
                "apostrophe",
                "comma",
                "dot",
                "slash",
                "grave_accent",
            ],
        )
    )
    shifted = dict(
        zip(
            '!@#$%^&*()_+{}|:"<>?~',
            [
                "1",
                "2",
                "3",
                "4",
                "5",
                "6",
                "7",
                "8",
                "9",
                "0",
                "minus",
                "equal",
                "bracket_left",
                "bracket_right",
                "backslash",
                "semicolon",
                "apostrophe",
                "comma",
                "dot",
                "slash",
                "grave_accent",
            ],
        )
    )
    names = []
    for char in text:
        if char in plain:
            names.append(plain[char])
        elif char in shifted:
            names.append("shift-" + shifted[char])
        elif char.isascii() and char.isalpha():
            names.append(("shift-" if char.isupper() else "") + char.lower())
        elif char in "0123456789":
            names.append(char)
        else:
            raise ValueError("console typing supports US ASCII keyboard text only")
    for name in names:
        key(qmp, name)


def prepare(work, args):
    if (work / "image.json").exists():
        raise ValueError(
            "workspace already prepared; reuse it or choose a new directory"
        )
    if (work / "macos.qcow2").exists():
        raise ValueError("existing disk without manifest; refusing to overwrite")
    source = work / "upstream"
    if not source.exists():
        run("git", "init", source, stdout=subprocess.DEVNULL)
        run("git", "-C", source, "fetch", "--depth=1", UPSTREAM, REVISION)
        run(
            "git",
            "-C",
            source,
            "checkout",
            "--detach",
            "FETCH_HEAD",
            stdout=subprocess.DEVNULL,
        )
    actual = run(
        "git", "-C", source, "rev-parse", "HEAD", capture_output=True, text=True
    ).stdout.strip()
    if actual != REVISION:
        raise ValueError("upstream checkout does not match pinned revision")
    run("git", "-C", source, "diff", "--exit-code", "HEAD", stdout=subprocess.DEVNULL)
    for src, dst in [
        ("OVMF_CODE_4M.fd", "OVMF_CODE.fd"),
        ("OVMF_VARS-1024x768.fd", "OVMF_VARS.fd"),
    ]:
        shutil.copyfile(source / src, work / dst)
    # Patch a private raw copy of the pinned boot disk, never the upstream checkout.
    raw = work / "opencore.raw"
    run(
        "qemu-img",
        "convert",
        "-f",
        "qcow2",
        "-O",
        "raw",
        source / "OpenCore/OpenCore.qcow2",
        raw,
    )
    with (source / "OpenCore/config.plist").open("rb") as stream:
        config = plistlib.load(stream)
    # Scan APFS and HFS only: including ESP exposes OpenCore itself as a default
    # EFI entry and can loop forever instead of booting the installed OS.
    config["Misc"]["Security"]["ScanPolicy"] = 1 | (1 << 8) | (1 << 9)
    config["Misc"]["Boot"]["Timeout"] = 5
    config["Misc"]["Boot"]["ShowPicker"] = True
    config["UEFI"]["Output"]["Resolution"] = "1024x768"
    with (work / "config.plist").open("wb") as stream:
        plistlib.dump(config, stream)
    run(
        "mcopy",
        "-o",
        "-i",
        f"{raw}@@1048576",
        work / "config.plist",
        "::/EFI/OC/config.plist",
    )
    run("qemu-img", "convert", "-f", "raw", "-O", "qcow2", raw, work / "OpenCore.qcow2")
    raw.unlink()
    run("qemu-img", "create", "-f", "qcow2", work / "macos.qcow2", f"{args.disk_gib}G")
    boot = (source / "OpenCore-Boot.sh").read_text()
    smc = re.search(r'isa-applesmc,osk="([^"]+)"', boot)
    if not smc:
        raise ValueError("pinned upstream SMC configuration was not found")
    manifest = {
        "schema": 1,
        "upstream_revision": REVISION,
        "macos": args.macos,
        "disk_gib": args.disk_gib,
        "memory_mib": args.memory_mib,
        "cpus": args.cpus,
        "uuid": str(uuid.uuid4()),
        "hardware_args": [
            "-machine",
            "q35",
            "-cpu",
            "Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check",
            "-device",
            "isa-applesmc,osk=" + smc[1],
            "-smbios",
            "type=2",
            "-global",
            "ICH9-LPC.disable_s3=1",
            "-global",
            "ICH9-LPC.disable_s4=1",
        ],
        "sealed": False,
    }
    write_json(work / "image.json", manifest)
    print("Prepared workspace. Run download, then run --installer.")


def download(work, manifest):
    recovery = work / "recovery"
    recovery.mkdir(exist_ok=True)
    if (work / "BaseSystem.img").exists():
        expected = manifest.get("recovery_sha256")
        if not expected or digest(work / "BaseSystem.img") != expected:
            raise ValueError("recovery image has no matching recorded checksum")
        return
    # Upstream verifies the recovery chunklist. Record the resulting bytes as well:
    # Apple may change what a major-version download resolves to on a future build.
    run(
        sys.executable,
        work / "upstream/fetch-macOS-v2.py",
        "-s",
        manifest["macos"],
        cwd=recovery,
    )
    run(
        "dmg2img",
        "-i",
        recovery / "BaseSystem.dmg",
        "-o",
        work / "BaseSystem.img.partial",
    )
    manifest["recovery_sha256"] = digest(work / "BaseSystem.img.partial")
    (work / "BaseSystem.img.partial").replace(work / "BaseSystem.img")
    write_json(work / "image.json", manifest)


def seed(work, manifest):
    directory = work / "seed"
    directory.mkdir(exist_ok=True)
    for name in ("install.sh", "provision.sh", "seal.sh"):
        shutil.copyfile(GUEST / name, directory / name)
    if (work / "bootstrap.pkg").exists():
        shutil.copyfile(work / "bootstrap.pkg", directory / "bootstrap.pkg")
    (directory / "disk-bytes").write_text(str(manifest["disk_gib"] * 1024**3))
    run(
        "xorriso",
        "-as",
        "mkisofs",
        "-quiet",
        "-J",
        "-r",
        "-V",
        "IMAGE_BUILD",
        "-o",
        work / "build.iso",
        directory,
    )


def qemu_args(work, manifest, args):
    command = [
        "qemu-system-x86_64",
        "-enable-kvm",
        "-nodefaults",
        "-no-user-config",
        "-name",
        "actions-vm-image",
        "-uuid",
        manifest["uuid"],
        "-m",
        str(manifest["memory_mib"]),
        "-smp",
        str(manifest["cpus"]),
        "-display",
        "none",
        "-vnc",
        f"127.0.0.1:{args.vnc_display}",
        "-qmp",
        f"unix:{work}/qmp.sock,server=on,wait=off",
        "-monitor",
        "none",
        "-serial",
        f"file:{work}/serial.log",
    ]
    command += manifest["hardware_args"]
    command += [
        "-drive",
        f"if=pflash,format=raw,readonly=on,file={work}/OVMF_CODE.fd",
        "-drive",
        f"if=pflash,format=raw,file={work}/OVMF_VARS.fd",
        "-device",
        "ich9-ahci,id=sata",
    ]
    disks = [
        ("opencore", "opencore-runtime.qcow2", "qcow2", 2, False),
        ("os", "macos.qcow2", "qcow2", 4, False),
    ]
    if args.installer:
        disks.append(("recovery", "BaseSystem.img", "raw", 1, True))
    for name, file, fmt, port, readonly in disks:
        command += [
            "-drive",
            f"id={name},if=none,format={fmt},file={work / file}"
            + (",snapshot=on" if readonly else ""),
            "-device",
            f"ide-hd,bus=sata.{port},drive={name}"
            + (",serial=ACTIONSVMBUILD" if name == "os" else ""),
        ]
    command += [
        "-drive",
        f"id=seed,if=none,format=raw,readonly=on,media=cdrom,file={work}/build.iso",
        "-device",
        "ide-cd,bus=sata.3,drive=seed",
        "-device",
        "VGA",
        "-device",
        "qemu-xhci,id=xhci",
        "-device",
        "usb-kbd,bus=xhci.0",
        "-device",
        "usb-tablet,bus=xhci.0",
        "-netdev",
        f"user,id=net0,hostfwd=tcp:127.0.0.1:{args.ssh_port}-:22",
        "-device",
        "vmxnet3,netdev=net0,mac=52:54:00:78:ff:01",
    ]
    return command


def child_setup():
    # Linux-specific: QEMU must die even if the foreground owner is SIGKILLed.
    parent = os.getppid()
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(1, signal.SIGKILL) != 0:
        raise OSError(ctypes.get_errno(), "setting QEMU parent-death signal")
    if parent == 1 or os.getppid() != parent:
        os.kill(os.getpid(), signal.SIGKILL)


def boot(work, manifest, args):
    if not Path("/dev/kvm").exists():
        raise ValueError("run requires Linux /dev/kvm")
    if len(str(work / "qmp.sock").encode()) >= 104:
        raise ValueError("workspace path is too long for the QMP Unix socket")
    if (work / "qmp.sock").exists():
        try:
            with QMP(work):
                pass
        except (ConnectionRefusedError, FileNotFoundError):
            pass
        else:
            raise ValueError("QEMU is already running in this workspace")
    if not 0 <= args.vnc_display <= 99 or not 1024 <= args.ssh_port <= 65535:
        raise ValueError("use VNC display 0..99 and an unprivileged SSH port")
    manifest["sealed"] = False
    write_json(work / "image.json", manifest)
    (work / "qmp.sock").unlink(missing_ok=True)
    seed(work, manifest)
    overlay = work / "opencore-runtime.qcow2"
    overlay.unlink(missing_ok=True)
    run(
        "qemu-img",
        "create",
        "-f",
        "qcow2",
        "-F",
        "qcow2",
        "-b",
        work / "OpenCore.qcow2",
        overlay,
    )
    command = qemu_args(work, manifest, args)
    write_json(
        work / "boot.json", {"installer": args.installer, "ssh_port": args.ssh_port}
    )
    print(
        f"VNC 127.0.0.1:{5900 + args.vnc_display}; SSH 127.0.0.1:{args.ssh_port}",
        flush=True,
    )
    # Foreground ownership: interrupting the builder must not leave QEMU orphaned.
    with (work / "qemu.log").open("ab") as log:
        child = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=log,
            preexec_fn=child_setup,  # noqa: PLW1509 - this CLI is single-threaded
        )
        try:
            if child.wait() != 0:
                raise RuntimeError(f"QEMU failed; inspect {work}/qemu.log")
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            (work / "qmp.sock").unlink(missing_ok=True)
            (work / "boot.json").unlink(missing_ok=True)


def ssh(work, args, command, **kwargs):
    if not re.fullmatch(r"[a-z_][a-z0-9_-]*", args.ssh_user):
        raise ValueError("invalid provisioning user")
    boot_state = json.loads((work / "boot.json").read_text())
    if args.ssh_port != boot_state["ssh_port"]:
        raise ValueError("SSH port does not match the running workspace")
    return run(
        "ssh",
        "-F",
        "/dev/null",
        "-o",
        "BatchMode=yes",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        f"UserKnownHostsFile={work}/known_hosts",
        "-o",
        "ConnectTimeout=10",
        "-p",
        args.ssh_port,
        "-i",
        safe_path(args.identity),
        f"{args.ssh_user}@127.0.0.1",
        command,
        **kwargs,
    )


def provision(work, manifest, args):
    if not re.fullmatch(r"[a-z_][a-z0-9_-]*", args.ssh_user):
        raise ValueError("invalid provisioning user")
    # Provision only a running workspace, using the same host identity on repeat calls.
    with QMP(work) as qmp:
        if qmp.call("query-status")["status"] != "running":
            raise ValueError("VM is not running")
    runner = safe_path(args.runner_archive)
    if digest(runner) != args.runner_sha256:
        raise ValueError("runner archive SHA256 mismatch")
    with tempfile.TemporaryDirectory(dir=work) as name:
        bundle = Path(name)
        shutil.copyfile(runner, bundle / "runner.tar.gz")
        shutil.copyfile(GUEST / "provision.sh", bundle / "provision.sh")
        for file in SCALER_GUEST.iterdir():
            if file.is_file():
                shutil.copyfile(file, bundle / file.name)
        if args.toolchain:
            toolchain = safe_path(args.toolchain)
            if not args.toolchain_sha256 or digest(toolchain) != args.toolchain_sha256:
                raise ValueError("toolchain SHA256 mismatch or missing hash")
            if toolchain.suffix not in (".xip", ".pkg"):
                raise ValueError("toolchain must be an Apple Xcode .xip or CLT .pkg")
            shutil.copyfile(toolchain, bundle / ("toolchain" + toolchain.suffix))
        if args.install_clt:
            (bundle / "install-clt").touch()
        # Use a unique guest staging directory and transfer without a shared host mount.
        remote = "/private/tmp/actions-image-" + uuid.uuid4().hex
        ssh(work, args, "mkdir -m 700 " + remote)
        archive = bundle / "payload.tar"
        import tarfile

        with tarfile.open(archive, "w") as tar:
            for file in bundle.iterdir():
                if file != archive:
                    tar.add(file, arcname=file.name)
        with archive.open("rb") as stream:
            ssh(work, args, "tar -xf - -C " + remote, stdin=stream)
        try:
            ssh(work, args, "sudo -n /bin/bash " + remote + "/provision.sh " + remote)
        finally:
            ssh(work, args, "rm -rf " + remote)
    manifest["runner_sha256"] = args.runner_sha256
    if args.toolchain:
        manifest["toolchain_sha256"] = args.toolchain_sha256
    manifest["provisioned"] = True
    write_json(work / "image.json", manifest)


def seal(work, manifest, args):
    if not manifest.get("provisioned"):
        raise ValueError("provision the image before sealing")
    password_file = (
        safe_path(args.builder_password_file) if args.builder_password_file else None
    )
    if password_file and password_file.stat().st_mode & 0o077:
        raise ValueError("builder password file must be private (mode 0600)")
    password = password_file.read_text().rstrip("\r\n") if password_file else ""
    if (password_file and not password) or "\n" in password or "\r" in password:
        raise ValueError("builder password must be a nonempty single line")
    # Send via SSH stdin, never argv, environment, logs, or a guest staging file.
    payload = ("builder_password=" + shlex.quote(password) + "\n").encode()
    payload += (GUEST / "seal.sh").read_bytes()
    try:
        receipt = ssh(
            work,
            args,
            "sudo -n /bin/bash -s -- "
            + ("xcode" if args.require_xcode else "clt")
            + " "
            + shlex.quote(args.ssh_user),
            input=payload,
            capture_output=True,
        ).stdout.decode()
    except subprocess.CalledProcessError as error:
        diagnostic = (error.stdout or b"") + (error.stderr or b"")
        (work / "seal-failure.log").write_bytes(diagnostic)
        raise RuntimeError(
            f"guest seal failed; inspect {work}/seal-failure.log"
        ) from error
    if "ACTIONS_VM_IMAGE_SEALED" not in receipt.splitlines():
        raise ValueError("guest did not provide a successful seal receipt")
    # The guest reports checks before requesting shutdown. Wait for QEMU to exit.
    deadline = time.monotonic() + 120
    while (work / "qmp.sock").exists():
        if time.monotonic() > deadline:
            raise ValueError("guest did not shut down; image remains unsealed")
        time.sleep(1)
    with locked(work):
        manifest["sealed"] = True
        manifest["validation"] = receipt
        write_json(work / "image.json", manifest)
    print(receipt)


def publish(work, manifest, args):
    if not manifest.get("sealed"):
        raise ValueError("seal and cleanly shut down the guest before publishing")
    destination = safe_path(args.destination)
    if destination.exists():
        raise ValueError("publication destination already exists; use a new version")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=".image-", dir=destination.parent))
    try:
        for file in ("macos.qcow2", "OpenCore.qcow2"):
            run("qemu-img", "check", "-f", "qcow2", work / file)
            run(
                "qemu-img",
                "convert",
                "-f",
                "qcow2",
                "-O",
                "qcow2",
                work / file,
                temporary / file,
            )
        for file in ("OVMF_CODE.fd", "OVMF_VARS.fd"):
            shutil.copyfile(work / file, temporary / file)
        published = dict(manifest)
        published["sha256"] = {p.name: digest(p) for p in temporary.iterdir()}
        write_json(temporary / "manifest.json", published)
        vm = {
            "base_disk": str(destination / "macos.qcow2"),
            "opencore_disk": str(destination / "OpenCore.qcow2"),
            "firmware_code": str(destination / "OVMF_CODE.fd"),
            "firmware_vars": str(destination / "OVMF_VARS.fd"),
            **{k: manifest[k] for k in ("hardware_args", "memory_mib", "cpus")},
        }
        write_json(temporary / "vm.json", vm)
        for file in temporary.iterdir():
            file.chmod(0o444)
        temporary.chmod(0o755)
        temporary.rename(destination)
    except BaseException:
        shutil.rmtree(temporary)
        raise
    print(f"Published {destination}; use vm.json as the scaler's vm settings.")


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


def main():
    signal.signal(signal.SIGTERM, interrupted)
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", required=True, type=safe_path)
    subs = parser.add_subparsers(dest="command", required=True)
    p = subs.add_parser("bootstrap-package", help="Build first-boot package on macOS")
    p.add_argument("--public-key", required=True)
    p.add_argument("--output", required=True)
    p = subs.add_parser(
        "build", help="Automate Sequoia Recovery, first boot, CLT and publication"
    )
    p.add_argument("--bootstrap-package", required=True)
    p.add_argument("--identity", required=True)
    p.add_argument("--runner-archive", required=True)
    p.add_argument("--runner-sha256", required=True)
    p.add_argument("--destination", required=True)
    p.add_argument("--timeout", type=int, default=10800)
    p.add_argument("--vnc-display", type=int, default=9)
    p.add_argument("--ssh-port", type=int, default=2229)
    p.set_defaults(
        macos="sequoia", disk_gib=128, memory_mib=8192, cpus=4, ssh_user="builder"
    )

    p = subs.add_parser("prepare")
    p.add_argument("--macos", choices=["sonoma", "sequoia", "tahoe"], default="sequoia")
    p.add_argument("--disk-gib", type=int, default=128)
    p.add_argument("--memory-mib", type=int, default=8192)
    p.add_argument("--cpus", type=int, default=4)
    subs.add_parser("download")
    p = subs.add_parser("run")
    p.add_argument("--installer", action="store_true")
    p.add_argument("--vnc-display", type=int, default=9)
    p.add_argument("--ssh-port", type=int, default=2229)
    for name in ("status", "stop", "screenshot", "install"):
        subs.add_parser(name)
    p = subs.add_parser("click")
    p.add_argument("x", type=int)
    p.add_argument("y", type=int)
    p.add_argument("--width", type=int, required=True)
    p.add_argument("--height", type=int, required=True)
    p = subs.add_parser("key")
    p.add_argument("keys")
    p = subs.add_parser("type")
    p.add_argument("text")
    for name in ("provision", "seal"):
        p = subs.add_parser(name)
        p.add_argument("--ssh-user", default="builder")
        p.add_argument("--ssh-port", type=int, default=2229)
        p.add_argument("--identity", required=True)
        if name == "provision":
            p.add_argument("--runner-archive", required=True)
            p.add_argument("--runner-sha256", required=True)
            toolchain = p.add_mutually_exclusive_group()
            toolchain.add_argument(
                "--toolchain", help="Apple Xcode .xip or Command Line Tools .pkg"
            )
            toolchain.add_argument(
                "--install-clt",
                action="store_true",
                help="Install Apple Command Line Tools through Software Update",
            )
            p.add_argument("--toolchain-sha256")
        else:
            p.add_argument("--require-xcode", action="store_true")
            p.add_argument("--builder-password-file")
    p = subs.add_parser("publish")
    p.add_argument("destination")
    args = parser.parse_args()
    work = args.work_dir
    if args.command in ("bootstrap-package", "build"):
        import automation

        if args.command == "bootstrap-package":
            automation.package(sys.modules[__name__], args)
        else:
            automation.build(sys.modules[__name__], args)
        return
    if args.command == "prepare":
        if args.disk_gib < 64 or args.memory_mib < 4096 or not 1 <= args.cpus <= 64:
            raise ValueError("require disk >=64 GiB, memory >=4096 MiB, 1..64 CPUs")
        with locked(work):
            prepare(work, args)
        return
    manifest = json.loads((work / "image.json").read_text())
    if args.command in ("download", "run", "publish"):
        with locked(work):
            if args.command == "download":
                download(work, manifest)
            elif args.command == "run":
                boot(work, manifest, args)
            else:
                publish(work, manifest, args)
    elif args.command in ("provision", "seal"):
        with (work / ".provision-lock").open("a") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if args.command == "provision":
                provision(work, manifest, args)
            else:
                seal(work, manifest, args)
    else:
        with QMP(work) as qmp:
            if args.command == "status":
                print(
                    json.dumps(
                        {"vm": qmp.call("query-status"), "kvm": qmp.call("query-kvm")}
                    )
                )
            elif args.command == "stop":
                qmp.call("quit")
            elif args.command == "screenshot":
                path = work / "screen.ppm"
                qmp.call("screendump", {"filename": str(path)})
                print(path)
            elif args.command == "click":
                if not (0 <= args.x < args.width and 0 <= args.y < args.height):
                    raise ValueError(
                        "click must be inside the observed screenshot dimensions"
                    )
                qmp.call(
                    "input-send-event",
                    {
                        "events": [
                            {
                                "type": "abs",
                                "data": {
                                    "axis": "x",
                                    "value": args.x * 32767 // args.width,
                                },
                            },
                            {
                                "type": "abs",
                                "data": {
                                    "axis": "y",
                                    "value": args.y * 32767 // args.height,
                                },
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
                            {"type": "btn", "data": {"down": False, "button": "left"}}
                        ]
                    },
                )
            elif args.command == "key":
                key(qmp, args.keys)
            elif args.command == "type":
                type_text(qmp, args.text)
            elif args.command == "install":
                boot_state = json.loads((work / "boot.json").read_text())
                if not boot_state["installer"]:
                    raise ValueError("install requires a VM started with --installer")
                # An exclusive marker makes the disk erase a one-time action.
                with (work / "install-requested").open("x") as marker:
                    marker.write("Recovery install requested\n")
                type_text(qmp, "/bin/bash /Volumes/IMAGE_BUILD/install.sh\n")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"actions-vm-image: {error}", file=sys.stderr)
        sys.exit(1)
