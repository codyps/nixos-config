"""Idempotent initrd credential provisioning and attended LUKS TPM enrollment."""

import argparse
import fcntl
import getpass
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

PLAIN_STORE = None
STORE = None
EFI = Path("/sys/firmware/efi/efivars")
EFI_GUID = "8be4df61-93ca-11d2-aa0d-00e098032b8c"


def run(*args):
    # Capture tool output: credentials and private key material must not be logged.
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def preflight(config, *, require_current_generation=True):
    require(os.geteuid() == 0, "Run with sudo on the installed host.")
    require(os.uname().nodename == config["hostName"],
            f"Run on the installed {config['hostName']}, not the installer.")
    for name, expected in [("SecureBoot", 1), ("SetupMode", 0)]:
        data = (EFI / f"{name}-{EFI_GUID}").read_bytes()
        require(len(data) == 5 and data[4] == expected,
                "Boot with Secure Boot enabled and Setup Mode disabled first.")
    require(Path("/dev/tpmrm0").exists(), "No TPM resource manager is available.")
    # Credential sealing binds only PCR 7 (Secure Boot policy), not the kernel
    # generation. Disk enrollment still requires the booted measured policy.
    if require_current_generation:
        require(Path("/run/booted-system").resolve() == Path("/run/current-system").resolve(),
                "Reboot into the current generation before provisioning TPM state.")
    source = run("findmnt", "--evaluate", "-n", "-o", "SOURCE", "--target", config["stateDirectory"]).decode().strip()
    # Btrfs st_dev/MAJ:MIN describes an anonymous filesystem device, not its
    # backing block device. Compare the resolved source after removing subvol.
    require(os.stat(source.split("[", 1)[0]).st_rdev == os.stat(f"/dev/mapper/{config['mapperName']}").st_rdev,
            "The state directory must be on the configured encrypted root mapping.")
    return config


def private_input(path):
    path = Path(path)
    require(not path.is_symlink(), f"Input must not be a symlink: {path}")
    info = path.stat()
    require(path.is_file() and info.st_uid == 0 and info.st_mode & 0o077 == 0,
            f"Input must be a root-owned file with mode 0600: {path}")
    return path


def decrypt(name, source, destination):
    run("systemd-creds", "decrypt", f"--name={name}", str(source), str(destination))


def publish(source, target):
    with tempfile.NamedTemporaryFile(dir=target.parent, prefix=".credential-", delete=False) as out:
        staged = Path(out.name)
        try:
            out.write(source.read_bytes())
            out.flush()
            os.fsync(out.fileno())
            os.replace(staged, target)
        finally:
            staged.unlink(missing_ok=True)


def credentials(args, work):
    for directory in (PLAIN_STORE, STORE):
        require(not directory.is_symlink(), f"Credential directory must not be a symlink: {directory}")
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        require(directory.stat().st_uid == os.geteuid(), "Credential directory has the wrong owner.")
        os.chmod(directory, 0o700)
    pending = []
    inputs = [("ssh-host-key", args.ssh_key_file)]
    if getattr(args, "tailscale", False):
        inputs.insert(0, ("tailscale-state", None))
    if not args.ssh_only:
        inputs.insert(0, ("wifi", args.wifi_file))
    for name, supplied in inputs:
        plain = work / name
        source = PLAIN_STORE / name
        target = STORE / name
        if supplied:
            plain.write_bytes(private_input(supplied).read_bytes())
        elif source.exists() or source.is_symlink():
            plain.write_bytes(private_input(source).read_bytes())
        elif target.exists():
            # Migrate an existing sealed-only credential without changing identity.
            decrypt(name, target, plain)
        elif name == "ssh-host-key":
            require(not (STORE / "ssh-host-key.pub").exists(),
                    "Initrd SSH ciphertext is missing; restore the plaintext key rather than rotating identity.")
            run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(plain))
        else:
            if name == "tailscale-state":
                raise RuntimeError("Run secure-unlock-setup enroll-tailscale before installing boot files.")
            raise RuntimeError(f"Install a root-owned mode-0600 Wi-Fi config at {PLAIN_STORE / 'wifi'}.")
        require(plain.stat().st_size > 0, f"Empty {name} credential.")
        if name == "ssh-host-key":
            public = run("ssh-keygen", "-y", "-f", str(plain))
            (work / "ssh-host-key.pub").write_bytes(public)
            saved_public = STORE / "ssh-host-key.pub"
            if saved_public.exists():
                old_public = saved_public.read_bytes()
            elif target.exists():
                previous = work / "previous-host-key"
                decrypt(name, target, previous)
                old_public = run("ssh-keygen", "-y", "-f", str(previous))
            else:
                old_public = public
            require(old_public.split()[:2] == public.split()[:2],
                    "Refusing to replace the existing initrd SSH identity.")
        # Keep ciphertext if it still decrypts to the authoritative input.
        # Otherwise reseal from plaintext under the verified current PCR 7 policy.
        reusable = False
        if target.exists():
            try:
                previous = work / f"{name}.previous"
                decrypt(name, target, previous)
                reusable = previous.read_bytes() == plain.read_bytes()
            except subprocess.CalledProcessError:
                pass
        if not reusable:
            encrypted = work / f"{name}.encrypted"
            run("systemd-creds", "encrypt", "--with-key=tpm2", "--tpm2-device=auto",
                "--tpm2-pcrs=7", f"--name={name}", str(plain), str(encrypted))
            check = work / f"{name}.check"
            decrypt(name, encrypted, check)
            require(check.read_bytes() == plain.read_bytes(), "Credential round-trip failed.")
            pending.append((encrypted, target))
        if supplied or not source.exists():
            pending.append((plain, source))
    # Validate every requested credential before publishing. Each file replacement
    # is atomic; plaintext stays on encrypted root, only ciphertext enters the initrd.
    for source, target in pending:
        publish(source, target)
    publish(work / "ssh-host-key.pub", STORE / "ssh-host-key.pub")
    print(run("ssh-keygen", "-lf", str(STORE / "ssh-host-key.pub")).decode().strip())
    print(f"Credentials sealed from {PLAIN_STORE}. Rebuild boot files to include changes.")


def validate_tailscale_status(status):
    require(status.get("BackendState") == "Running" and status.get("Self", {}).get("ID"),
            "The initrd Tailscale node must be authenticated and running.")
    expiry = status["Self"].get("KeyExpiry")
    require(expiry is None or expiry == "0001-01-01T00:00:00Z",
            "Disable key expiry for the initrd node in the Tailscale admin console, then rerun enroll-tailscale.")


def enroll_tailscale(config, work):
    require(config.get("tailscale"), "Enable boot.secureUnlock.remoteUnlock.tailscale.enable first.")
    # A separate persistent workspace permits retrying authentication without
    # rotating identity. Never read or copy the main host's Tailscale state.
    directory = Path(config["stateDirectory"]) / "tailscale-initrd"
    require(not directory.is_symlink(), "Initrd Tailscale directory must not be a symlink.")
    directory.mkdir(mode=0o700, exist_ok=True)
    require(directory.stat().st_uid == os.geteuid(), "Initrd Tailscale directory must be root-owned.")
    directory.chmod(0o700)
    state = directory / "tailscaled.state"
    source = PLAIN_STORE / "tailscale-state"
    if state.exists() or state.is_symlink():
        private_input(state)
    elif source.exists():
        publish(private_input(source), state)
    elif (STORE / "tailscale-state").exists():
        decrypt("tailscale-state", STORE / "tailscale-state", state)
    socket = work / "tailscaled.sock"
    cli = ("tailscale", f"--socket={socket}")
    daemon = subprocess.Popen(
        ["tailscaled", f"--state={state}", f"--statedir={directory}", f"--socket={socket}",
         "--tun=userspace-networking", "--port=0", "--encrypt-state=false"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            require(daemon.poll() is None, "The isolated Tailscale provisioning daemon exited.")
            if socket.exists():
                break
            time.sleep(0.1)
        require(socket.exists(), "The isolated Tailscale provisioning socket did not appear.")
        # Interactive login URL goes only to the operator. No auth key is stored
        # in Nix or passed to the normal host's daemon.
        subprocess.run([*cli, "up", f"--hostname={config['tailscaleHostName']}",
                        "--accept-dns=false", "--accept-routes=false", "--netfilter-mode=off",
                        "--ssh=false", "--timeout=5m"], check=True)
        status = json.loads(run(*cli, "status", "--json"))
        validate_tailscale_status(status)
    finally:
        daemon.terminate()
        try:
            daemon.wait(timeout=10)
        except subprocess.TimeoutExpired:
            daemon.kill()
            daemon.wait()
    require(not PLAIN_STORE.is_symlink(), "Credential directory must not be a symlink.")
    PLAIN_STORE.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(PLAIN_STORE.stat().st_uid == os.geteuid(), "Credential directory must be root-owned.")
    PLAIN_STORE.chmod(0o700)
    publish(private_input(state), source)
    args = argparse.Namespace(ssh_key_file=None, wifi_file=None,
                              ssh_only=not config["wifi"], tailscale=True)
    credentials(args, work)
    print(f"Separate initrd Tailscale node {config['tailscaleHostName']} sealed. Rebuild boot files before testing.")


def recovery_slots(metadata):
    token_slots = {slot for token in metadata["tokens"].values() for slot in token["keyslots"]}
    return sorted(set(metadata["keyslots"]) - token_slots)


def enroll_disk(config, work):
    require(config["diskUnlock"], "Enable boot.secureUnlock.tpmUnlock.enable, rebuild boot files, then reboot first.")
    require(run(config["pcrlock"], "is-supported").strip() == b"yes", "pcrlock is unsupported.")
    require(Path(config["policy"]).is_file(), "No pcrlock policy; finish the measured-boot setup first.")
    disk = config["disk"]
    metadata = json.loads(run("cryptsetup", "luksDump", "--dump-json-metadata", disk))
    slots = recovery_slots(metadata)
    require(slots, "No token-free recovery passphrase slot; refusing enrollment.")
    existing = [t for t in metadata["tokens"].values() if t.get("type") == "systemd-tpm2"]
    if existing:
        require(all(t.get("tpm2_pcrlock") for t in existing),
                "Existing TPM enrollment uses another policy; migrate it explicitly.")
        print("TPM pcrlock token already present; left unchanged. Verify automatic unlock by rebooting.")
        return
    key = work / "luks-passphrase"
    key.write_text(getpass.getpass("Existing LUKS recovery passphrase: "))
    verified = False
    for slot in slots:
        try:
            run("cryptsetup", "open", "--test-passphrase", "--key-slot", slot,
                "--key-file", str(key), disk)
            verified = True
            break
        except subprocess.CalledProcessError:
            pass
    require(verified, "Recovery passphrase did not unlock a token-free slot; no enrollment performed.")
    run("systemd-cryptenroll", "--tpm2-device=auto", "--tpm2-with-pin=false",
        f"--tpm2-pcrlock={config['policy']}", f"--unlock-key-file={key}", disk)
    after = json.loads(run("cryptsetup", "luksDump", "--dump-json-metadata", disk))
    require(all(after["keyslots"].get(s) == metadata["keyslots"][s] for s in metadata["keyslots"]),
            "Existing keyslots changed unexpectedly; inspect LUKS metadata before rebooting.")
    require(any(t.get("type") == "systemd-tpm2" and t.get("tpm2_pcrlock")
                for t in after["tokens"].values()), "Enrollment did not create a pcrlock TPM token.")
    print("TPM enrolled; recovery slots preserved. Test a reboot with console access available.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path("/etc/secure-unlock.json"))
    commands = parser.add_subparsers(dest="command", required=True)
    creds = commands.add_parser("credentials", help="Seal or verify initrd SSH/Wi-Fi credentials")
    creds.add_argument("--wifi-file", type=Path)
    creds.add_argument("--ssh-key-file", type=Path, help="Import an existing key into the configured credential store; otherwise reuse or generate once")
    creds.add_argument("--ssh-only", action="store_true", help="Provision Ethernet SSH without Wi-Fi credentials")
    commands.add_parser("enroll-disk", help="Verify recovery passphrase and add a TPM LUKS token")
    commands.add_parser("enroll-tailscale", help="Register and seal a separate non-expiring initrd Tailscale node")
    args = parser.parse_args()
    os.umask(0o077)
    require(not (args.command == "credentials" and args.ssh_only and args.wifi_file),
            "--ssh-only cannot be combined with --wifi-file.")
    config = json.loads(args.config.read_text())
    if args.command == "credentials":
        args.tailscale = config.get("tailscale", False)
    if args.command == "credentials" and not config["wifi"]:
        require(not args.wifi_file, "Enable Wi-Fi in the host configuration before supplying credentials.")
        args.ssh_only = True
    global PLAIN_STORE, STORE
    PLAIN_STORE = Path(config["stateDirectory"]) / "credstore"
    STORE = Path(config["stateDirectory"]) / "credstore.encrypted"
    preflight(config, require_current_generation=args.command == "enroll-disk")
    with open("/run/secure-unlock-setup.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with tempfile.TemporaryDirectory(prefix="secure-unlock-", dir="/run") as directory:
            work = Path(directory)
            if args.command == "credentials":
                credentials(args, work)
            elif args.command == "enroll-tailscale":
                enroll_tailscale(config, work)
            else:
                enroll_disk(config, work)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        # Do not echo subprocess stdout/stderr, which may contain secret material.
        message = "A provisioning tool failed; no secret output was printed." if isinstance(
            error, subprocess.CalledProcessError) else str(error)
        sys.exit(message)
