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

STORE = Path("/persist/credstore.encrypted")
EFI = Path("/sys/firmware/efi/efivars")
EFI_GUID = "8be4df61-93ca-11d2-aa0d-00e098032b8c"


def run(*args):
    # Capture tool output: credentials and private key material must not be logged.
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def preflight(*, require_current_generation=True):
    require(os.geteuid() == 0, "Run with sudo on warbler.")
    require(os.uname().nodename == "warbler", "Run on the installed warbler, not the installer.")
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
    source = run("findmnt", "--evaluate", "-n", "-o", "SOURCE", "--mountpoint", "/persist").decode().strip()
    # Btrfs st_dev/MAJ:MIN describes an anonymous filesystem device, not its
    # backing block device. Compare the resolved source after removing subvol.
    require(os.stat(source.split("[", 1)[0]).st_rdev == os.stat("/dev/mapper/cryptroot").st_rdev,
            "/persist must be mounted from cryptroot.")
    return json.loads(Path("/etc/warbler-tpm.json").read_text())


def private_input(path):
    path = Path(path)
    info = path.stat()
    require(path.is_file() and info.st_uid == 0 and info.st_mode & 0o077 == 0,
            f"Input must be a root-owned file with mode 0600: {path}")
    return path


def decrypt(name, source, destination):
    run("systemd-creds", "decrypt", f"--name={name}", str(source), str(destination))


def credentials(args, work):
    STORE.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(STORE, 0o700)
    pending = []
    inputs = [("ssh-host-key", args.ssh_key_file)]
    if not args.ssh_only:
        inputs.insert(0, ("wifi", args.wifi_file))
    for name, supplied in inputs:
        plain = work / name
        target = STORE / name
        if supplied:
            plain.write_bytes(private_input(supplied).read_bytes())
        elif target.exists():
            # Fail rather than silently rotating an identity after TPM/policy loss.
            decrypt(name, target, plain)
        elif name == "ssh-host-key":
            require(not (STORE / "ssh-host-key.pub").exists(),
                    "Initrd SSH ciphertext is missing; restore it rather than rotating the saved identity.")
            run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(plain))
        else:
            raise RuntimeError("First setup needs --wifi-file /run/warbler-wifi.conf (mode 0600).")
        require(plain.stat().st_size > 0, f"Empty {name} credential.")
        if name == "ssh-host-key":
            public = run("ssh-keygen", "-y", "-f", str(plain))
            (work / "ssh-host-key.pub").write_bytes(public)
            if supplied and (target.exists() or (STORE / "ssh-host-key.pub").exists()):
                saved_public = STORE / "ssh-host-key.pub"
                if saved_public.exists():
                    old_public = saved_public.read_bytes()
                else:
                    previous = work / "previous-host-key"
                    decrypt(name, target, previous)
                    old_public = run("ssh-keygen", "-y", "-f", str(previous))
                require(old_public.split()[:2] == public.split()[:2],
                        "Refusing to replace the existing initrd SSH identity.")
        if supplied or not target.exists():
            encrypted = work / f"{name}.encrypted"
            run("systemd-creds", "encrypt", "--with-key=tpm2", "--tpm2-device=auto",
                "--tpm2-pcrs=7", f"--name={name}", str(plain), str(encrypted))
            check = work / f"{name}.check"
            decrypt(name, encrypted, check)
            require(check.read_bytes() == plain.read_bytes(), "Credential round-trip failed.")
            pending.append((encrypted, target))
    # Validate all requested credentials before publishing changes. Only ciphertext
    # crosses onto persistent storage; each rename is atomic on that filesystem.
    for source, target in pending:
        with tempfile.NamedTemporaryFile(dir=STORE, prefix=".sealed-", delete=False) as out:
            staged = Path(out.name)
            try:
                out.write(source.read_bytes())
                out.flush()
                os.fsync(out.fileno())
                os.replace(staged, target)
            finally:
                staged.unlink(missing_ok=True)
    (STORE / "ssh-host-key.pub").write_bytes((work / "ssh-host-key.pub").read_bytes())
    print(run("ssh-keygen", "-lf", str(STORE / "ssh-host-key.pub")).decode().strip())
    print("Credentials verified. Enable remoteUnlock and rebuild boot files to include them.")


def recovery_slots(metadata):
    token_slots = {slot for token in metadata["tokens"].values() for slot in token["keyslots"]}
    return sorted(set(metadata["keyslots"]) - token_slots)


def enroll_disk(config, work):
    require(config["diskUnlock"], "Enable warbler.tpmUnlock.enable, rebuild boot files, then reboot first.")
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
    commands = parser.add_subparsers(dest="command", required=True)
    creds = commands.add_parser("credentials", help="Seal or verify initrd SSH/Wi-Fi credentials")
    creds.add_argument("--wifi-file", type=Path)
    creds.add_argument("--ssh-key-file", type=Path, help="Existing key to preserve; otherwise generated once")
    creds.add_argument("--ssh-only", action="store_true", help="Provision Ethernet SSH without Wi-Fi credentials")
    commands.add_parser("enroll-disk", help="Verify recovery passphrase and add a TPM LUKS token")
    args = parser.parse_args()
    os.umask(0o077)
    require(not (args.command == "credentials" and args.ssh_only and args.wifi_file),
            "--ssh-only cannot be combined with --wifi-file.")
    config = preflight(require_current_generation=args.command == "enroll-disk")
    with open("/run/warbler-tpm-setup.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with tempfile.TemporaryDirectory(prefix="warbler-tpm-", dir="/run") as directory:
            work = Path(directory)
            if args.command == "credentials":
                credentials(args, work)
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
