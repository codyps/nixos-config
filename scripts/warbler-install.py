#!/usr/bin/env python3
"""Local secret preparation and attended remote LiveCD install; never changes BIOS."""

import argparse
import io
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tarfile
import tempfile
import uuid

REPO = Path(__file__).resolve().parents[1]
TARGET = "nixos@nixos.bed.einic.org"
DISK = "/dev/nvme0n1"
DEFAULT_SECRETS = Path.home() / ".local/share/warbler-install"
CONFIG = "path:.#nixosConfigurations.warbler-bootstrap.config"
NIX = "nix --extra-experimental-features 'nix-command flakes'"


def run(argv, *, data=None, cwd=None):
    # Capture output even on errors: tools must never dump private material.
    result = subprocess.run(argv, input=data, cwd=cwd, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(f"{argv[0]} failed (exit {result.returncode}); output withheld")
    return result.stdout


def private_path(path):
    path = Path(path).absolute()
    for component in [path, *path.parents]:
        if component.is_symlink():
            raise RuntimeError("Secret paths must not contain symlinks")
    path = path.resolve()
    if path == REPO or REPO in path.parents:
        raise RuntimeError("Secrets must be outside the checkout: path:. includes ignored files")
    return path


def write_private(path, data):
    with path.open("xb") as out:
        os.chmod(path, 0o600)
        out.write(data)


def validate_bundle(directory, *, require_ssh=True):
    directory = private_path(directory)
    expected = [directory, directory / "luks-password", directory / "sbctl/GUID"]
    for name in ("PK", "KEK", "db"):
        expected += [directory / f"sbctl/keys/{name}/{name}.{ext}" for ext in ("key", "pem")]
    for path in expected:
        if path.is_symlink() or not path.exists():
            raise RuntimeError("Incomplete secret bundle; refusing to rotate or overwrite it")
    for path in [directory, *directory.rglob("*")]:
        st = path.lstat()
        if path.is_symlink() or st.st_uid != os.getuid() or st.st_mode & 0o077:
            raise RuntimeError("Secret bundle must be owned by this user, directories 0700/files 0600")
    password = (directory / "luks-password").read_bytes()
    if len(password) < 20 or not re.fullmatch(rb"[A-Za-z0-9-]+", password):
        raise RuntimeError("Unexpected apple-password-gen output")
    uuid.UUID((directory / "sbctl/GUID").read_text().strip())
    for name in ("PK", "KEK", "db"):
        base = directory / f"sbctl/keys/{name}/{name}"
        key = base.with_suffix(".key")
        cert = base.with_suffix(".pem")
        if not key.read_bytes().startswith(b"-----BEGIN PRIVATE KEY-----"):
            raise RuntimeError("sbctl requires an unencrypted PKCS#8 private key")
        run(["openssl", "pkey", "-in", str(key), "-check", "-noout"])
        public = run(["openssl", "pkey", "-in", str(key), "-pubout"])
        certified = run(["openssl", "x509", "-in", str(cert), "-pubkey", "-noout"])
        if public != certified:
            raise RuntimeError("Signing key does not match its certificate")
        run(["openssl", "x509", "-in", str(cert), "-checkend", "86400", "-noout"])
    if require_ssh or (directory / "ssh").exists():
        validate_host_key(directory / "ssh")
    if (directory / "account-passwords").exists():
        validate_account_passwords(directory / "account-passwords")
    return directory


def validate_host_key(directory):
    key = directory / "ssh_host_ed25519_key"
    public = directory / "ssh_host_ed25519_key.pub"
    for path in (directory, key, public):
        if path.is_symlink() or not path.exists():
            raise RuntimeError("Incomplete SSH identity; refusing replacement")
        if path.stat().st_uid != os.getuid() or path.stat().st_mode & 0o077:
            raise RuntimeError("SSH identity must have private permissions")
    actual = run(["ssh-keygen", "-y", "-f", str(key)]).split()
    if actual[:1] != [b"ssh-ed25519"] or actual[:2] != public.read_bytes().split()[:2]:
        raise RuntimeError("SSH host key and public key do not match")


def ensure_host_key(directory):
    destination = directory / "ssh"
    if destination.exists() or destination.is_symlink():
        validate_host_key(destination)
        return
    with tempfile.TemporaryDirectory(prefix=".ssh-prepare-", dir=directory) as temporary:
        stage = Path(temporary) / "ssh"
        stage.mkdir(mode=0o700)
        run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "warbler stage-2/SOPS",
             "-f", str(stage / "ssh_host_ed25519_key")])
        for path in stage.iterdir():
            path.chmod(0o600)
        validate_host_key(stage)
        stage.rename(destination)


def ensure_account_passwords(directory):
    destination = directory / "account-passwords"
    if destination.exists() or destination.is_symlink():
        validate_account_passwords(destination)
        return
    with tempfile.TemporaryDirectory(prefix=".accounts-prepare-", dir=directory) as temporary:
        stage = Path(temporary) / "account-passwords"
        stage.mkdir(mode=0o700)
        for account in ("root", "cody"):
            write_private(stage / account, run(["apple-password-gen"]).strip())
        validate_account_passwords(stage)
        stage.rename(destination)


def validate_account_passwords(directory):
    for path in (directory, directory / "root", directory / "cody"):
        if path.is_symlink() or not path.exists():
            raise RuntimeError("Incomplete account-password bundle; refusing replacement")
        info = path.stat()
        if info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise RuntimeError("Account-password bundle must have private permissions")
    for account in ("root", "cody"):
        password = (directory / account).read_bytes()
        if len(password) < 20 or not re.fullmatch(rb"[A-Za-z0-9-]+", password):
            raise RuntimeError("Unexpected apple-password-gen account password output")


def verify_registered_host_key(directory):
    registered = (REPO / "hosts/warbler/ssh-host-key.pub").read_bytes().split()[:2]
    supplied = (directory / "ssh/ssh_host_ed25519_key.pub").read_bytes().split()[:2]
    if registered != supplied:
        raise RuntimeError("Bundle SSH key differs from Warbler's registered SOPS/SSH identity")


def prepare(directory):
    directory = private_path(directory)
    if directory.exists():
        validate_bundle(directory, require_ssh=False)
        ensure_host_key(directory)
        ensure_account_passwords(directory)
        validate_bundle(directory)
        print(f"Existing bundle verified and retained: {directory}")
        return
    directory.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix=".warbler-prepare-", dir=directory.parent) as temporary:
        stage = Path(temporary) / "bundle"
        stage.mkdir(mode=0o700)
        # The generator takes no flags; even --help can produce a password.
        password = run(["apple-password-gen"]).strip()
        write_private(stage / "luks-password", password)
        (stage / "sbctl").mkdir(mode=0o700)
        write_private(stage / "sbctl/GUID", str(uuid.uuid4()).encode())
        for name in ("PK", "KEK", "db"):
            base = stage / f"sbctl/keys/{name}/{name}"
            base.parent.mkdir(parents=True, mode=0o700)
            run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:4096",
                 "-out", str(base.with_suffix(".key"))])
            run(["openssl", "req", "-new", "-x509", "-sha256", "-days", "1825",
                 "-key", str(base.with_suffix(".key")), "-out", str(base.with_suffix(".pem")),
                 "-subj", f"/CN=warbler {name}/"])
        # Defense if this directory is ever copied under a Git worktree.
        write_private(stage / ".gitignore", b"*\n")
        ensure_host_key(stage)
        ensure_account_passwords(stage)
        validate_bundle(stage)
        if directory.exists():
            raise RuntimeError("Destination appeared during preparation; refusing overwrite")
        stage.rename(directory)
    print(f"Prepared private bundle: {directory} (no secrets printed)")


def source_archive():
    names = run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                cwd=REPO).split(b"\0")
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        for raw in sorted(set(names)):
            if not raw:
                continue
            relative = Path(os.fsdecode(raw))
            if relative.is_absolute() or ".." in relative.parts or relative.parts[0] in (".git", "keys"):
                raise RuntimeError("Unsafe or private path in source inventory")
            source = REPO / relative
            if source.is_symlink():
                raise RuntimeError("Source symlinks require review before installation")
            if not source.exists():  # Preserve local tracked deletions.
                continue
            if not source.is_file():
                raise RuntimeError("Only regular source files may be transferred")
            archive.add(source, arcname=str(relative), recursive=False)
    return buffer.getvalue()


def ssh(command, data=None):
    return run(["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30", TARGET,
                "sudo -n bash -c " + shlex.quote("set -euo pipefail; " + command)], data=data)


def inspect_target():
    ssh("test $(hostname) = nixos; test $(uname -m) = x86_64; "
        "test -d /sys/firmware/efi; test -e /dev/tpmrm0; "
        "test -e /etc/NIXOS; test ! -e /dev/mapper/cryptroot")
    info = json.loads(ssh(f"lsblk --json --bytes -o PATH,TYPE,SIZE,MODEL,FSTYPE,MOUNTPOINTS {DISK}"))
    disks = info["blockdevices"]
    if len(disks) != 1:
        raise RuntimeError("Unexpected disk inventory")
    disk = disks[0]
    if (disk["path"] != DISK or disk["type"] != "disk" or
            not 500_000_000_000 <= int(disk["size"]) <= 520_000_000_000 or
            "SK hynix" not in (disk["model"] or "").replace("_", " ") or
            disk.get("fstype") or disk.get("children") or any(disk.get("mountpoints") or [])):
        raise RuntimeError("Expected an unpartitioned, unmounted 512 GB SK hynix NVMe; refusing install")
    ssh("! findmnt -rn -o TARGET | grep -E '^/mnt(/|$)' >/dev/null; "
        "test ! -e /tmp/warbler-luks-password; test ! -L /tmp/warbler-luks-password")
    print(f"Verified {TARGET}: {DISK}, {disk['model'].strip()}, {disk['size']} bytes; no partitions/mounts")


def secret_archive(directory):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        archive.add(directory / "luks-password", arcname="luks-password")
        archive.add(directory / "sbctl", arcname="sbctl")
        archive.add(directory / "ssh", arcname="ssh")
        archive.add(directory / "account-passwords", arcname="account-passwords")
    return buffer.getvalue()


def volume_identity_script(system, checkout):
    """Pin only the freshly installed volume, using its existing recovery input."""
    helper = shlex.quote(str(Path(system) / "sw/bin/warbler-root-volume-key-id"))
    output = shlex.quote(str(Path(checkout) / "hosts/warbler/volume-identity.nix"))
    return f"""
warbler_volume_key_id=$({helper} --key-file /tmp/warbler-luks-password)
if [[ ! "$warbler_volume_key_id" =~ ^[0-9a-f]{{64}}$ ]]; then
    echo 'Invalid root volume identity; refusing to record it.' >&2
    exit 1
fi
printf '\"%s\"\\n' "$warbler_volume_key_id" > {output}
unset warbler_volume_key_id
"""


def install(directory, *, build_only=False):
    directory = validate_bundle(directory)
    if not build_only:
        ensure_account_passwords(directory)
        validate_account_passwords(directory / "account-passwords")
        print(f"Initial account passwords retained locally: {directory / 'account-passwords'} (not printed)")
    verify_registered_host_key(directory)
    inspect_target()
    # Nothing secret goes in source or the Nix input. Stage only in live RAM.
    work = ssh("mktemp -d /run/warbler-install.XXXXXXXX").decode().strip()
    if not re.fullmatch(r"/run/warbler-install\.[A-Za-z0-9]+", work):
        raise RuntimeError("Unexpected staging path")
    q = shlex.quote(work)
    try:
        ssh(f"mkdir -m 700 {q}/source {q}/secrets")
        ssh(f"tar -xzf - --no-same-owner -C {q}/source", source_archive())
        print("Building bootstrap system and disko on the live host (no secrets supplied)...", flush=True)
        root = f"cd {q}/source; "
        configured = ssh(root + f"{NIX} eval --raw {CONFIG}.disko.devices.disk.system.device").decode()
        if configured != DISK:
            raise RuntimeError("Evaluated disko target differs from inspected disk")
        disks = json.loads(ssh(root + f"{NIX} eval --json {CONFIG}.disko.devices.disk --apply builtins.attrNames"))
        if disks != ["system"]:
            raise RuntimeError("Unexpected additional disko disks")
        outputs = []
        for attribute in ("system.build.toplevel", "system.build.diskoScript"):
            output = ssh(root + f"{NIX} build --accept-flake-config --no-link --print-out-paths {CONFIG}.{attribute}").decode().strip()
            if not re.fullmatch(r"/nix/store/[a-z0-9]{32}-[^/\s]+", output):
                raise RuntimeError("Unexpected build output")
            outputs.append(output)
        inspect_target()
        if build_only:
            print("Bootstrap and disko built successfully; no secrets transferred or disks changed.")
            return
        confirmation = f"ERASE {DISK} ON {TARGET}"
        if input(f"Backups and local console ready? Type exactly:\n{confirmation}\n> ") != confirmation:
            raise RuntimeError("Installation cancelled before formatting")
        inspect_target()
        ssh(f"tar -xf - --no-same-owner -C {q}/secrets", secret_archive(directory))
        # The installer never reboots, changes Wi-Fi, clears the TPM, or enrolls
        # firmware keys. Signing happens at bootloader installation, not build.
        script = f"""
set -euo pipefail
exec 9>/run/warbler-install.lock
flock -n 9
test "$(lsblk -nr -o PATH {DISK} | wc -l)" -eq 1
test -z "$(lsblk -nr -o MOUNTPOINTS,FSTYPE {DISK} | tr -d '[:space:]')"
test ! -e /dev/mapper/cryptroot
! findmnt -rn -o TARGET | grep -E '^/mnt(/|$)' >/dev/null
test ! -e /tmp/warbler-luks-password
test ! -L /tmp/warbler-luks-password
trap 'rm -f /tmp/warbler-luks-password' EXIT
install -m 600 {q}/secrets/luks-password /tmp/warbler-luks-password
{shlex.quote(outputs[1])}
for mount in /mnt /mnt/nix /mnt/home /mnt/persist /mnt/boot; do
    mountpoint -q "$mount"
done
mkdir -p /mnt/persist/var/lib/sbctl /mnt/persist/nixos-config /mnt/persist/ssh
cp -a {q}/secrets/sbctl/. /mnt/persist/var/lib/sbctl/
cp -a {q}/secrets/ssh/. /mnt/persist/ssh/
cp -a {q}/source/. /mnt/persist/nixos-config/
{volume_identity_script(outputs[0], '/mnt/persist/nixos-config')}
{shlex.quote(outputs[0])}/sw/bin/warbler-account-passwords initialize --root /mnt --password-dir {q}/secrets/account-passwords
nixos-install --no-root-passwd --system {shlex.quote(outputs[0])}
sync
"""
        print("Installing to the confirmed NVMe; no automatic reboot...", flush=True)
        ssh(script)
        print("Bootstrap installed. Follow README step 5 (first NVMe boot), then continue the Secure Boot setup sequence.")
    finally:
        # Exact per-run mktemp directory validated above, never a broad path.
        ssh(f"rm -rf -- {q}")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "check", "build", "install"))
    parser.add_argument("--secrets-dir", type=Path, default=DEFAULT_SECRETS)
    args = parser.parse_args()
    try:
        if args.action == "prepare":
            prepare(args.secrets_dir)
        elif args.action == "check":
            directory = validate_bundle(args.secrets_dir)
            verify_registered_host_key(directory)
            inspect_target()
        else:
            install(args.secrets_dir, build_only=args.action == "build")
    except (OSError, ValueError, RuntimeError, EOFError, KeyboardInterrupt) as error:
        print(f"Stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
