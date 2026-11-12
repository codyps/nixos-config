"""Provision TPM-sealed restic credentials and compose runtime repository settings.

Repository access needs two secrets that never leave Crow in any form, not
even encrypted in Git: the restic repository encryption password and the
TrueNAS REST-server basic-auth password. Both are sealed to the TPM with the
same PCR 7 (Secure Boot policy) binding as the secure-unlock credentials and
are stored only as ciphertext in /persist/credstore.encrypted. The repository
endpoint URL and username are SOPS-encrypted in backup-secrets.yaml.

The `service` subcommand is run by restic-backup-credentials.service: it
receives the unsealed credentials and the SOPS values through systemd
credentials and writes the root-only runtime files consumed by the restic
backup unit.
"""

import argparse
import getpass
import os
import secrets
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import quote, urlsplit

HOST = "crow"
SEALED_STORE = Path("/persist/credstore.encrypted")
CREDENTIALS = ("restic-password", "rest-server-password")
EFI = Path("/sys/firmware/efi/efivars")
EFI_GUID = "8be4df61-93ca-11d2-aa0d-00e098032b8c"


def run(*args):
    # Capture tool output: credential material must not be logged.
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sealed(name):
    path = SEALED_STORE / name
    return path.exists() or path.is_symlink()


def secure_boot_ready():
    for name, expected in [("SecureBoot", 1), ("SetupMode", 0)]:
        data = (EFI / f"{name}-{EFI_GUID}").read_bytes()
        require(len(data) == 5 and data[4] == expected,
                "Boot with Secure Boot enabled and Setup Mode disabled first.")


def preflight():
    require(os.geteuid() == 0, "Run with sudo on the installed crow.")
    require(os.uname().nodename == HOST, f"Run on the installed {HOST}, not another host or the installer.")
    require(Path("/dev/tpmrm0").exists(), "No TPM resource manager is available.")
    # Never seal a credential to a disabled Secure Boot policy.
    secure_boot_ready()
    require(not SEALED_STORE.is_symlink(), f"Credential directory must not be a symlink: {SEALED_STORE}")
    SEALED_STORE.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(SEALED_STORE.stat().st_uid == os.geteuid(), "Credential directory has the wrong owner.")
    os.chmod(SEALED_STORE, 0o700)


def decrypt(name, source):
    with tempfile.TemporaryDirectory(prefix=".backup-keys-", dir="/run") as work:
        target = Path(work) / name
        run("systemd-creds", "decrypt", f"--name={name}", str(source), str(target))
        return target.read_bytes()


def seal(name, value):
    """Seal under the PCR 7 policy shared with the secure-unlock credentials."""
    with tempfile.TemporaryDirectory(prefix=".backup-keys-", dir="/run") as work:
        directory = Path(work)
        plain = directory / name
        plain.write_bytes(value)
        os.chmod(plain, 0o600)
        encrypted = directory / f"{name}.cred"
        run("systemd-creds", "encrypt", "--with-key=tpm2", "--tpm2-device=auto",
            "--tpm2-pcrs=7", f"--name={name}", str(plain), str(encrypted))
        check = directory / "check"
        run("systemd-creds", "decrypt", f"--name={name}", str(encrypted), str(check))
        require(check.read_bytes() == value, "Credential round-trip failed.")
        # Publish atomically within the sealed store; os.replace cannot
        # rename across filesystems from the /run staging directory.
        target = SEALED_STORE / name
        staged = SEALED_STORE / f".{name}.publish"
        try:
            fd = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as out:
                out.write(encrypted.read_bytes())
                out.flush()
                os.fsync(out.fileno())
            os.replace(staged, target)
        finally:
            staged.unlink(missing_ok=True)


def generate(args):
    preflight()
    names = CREDENTIALS if args.only is None else (args.only,)
    for name in names:
        if sealed(name):
            print(f"{name}: already sealed; kept (use 'enter' to replace it).")
            continue
        value = secrets.token_urlsafe(32).encode()
        seal(name, value)
        print(f"{name}: generated and sealed. Shown once; store it in a password manager now:")
        print(f"  {value.decode()}")
    if not all(sealed(name) for name in CREDENTIALS):
        print("Every credential must be sealed before the backup can run.")


def enter(args):
    preflight()
    first = getpass.getpass(f"{args.name}: ")
    second = getpass.getpass(f"{args.name} (again): ")
    require(first != "" and first == second, "The entered values are empty or do not match.")
    require("\n" not in first and "\r" not in first, "The value must not contain newlines.")
    if first != first.strip():
        # Almost always an accidental paste artifact; point it out but seal verbatim.
        print(f"warning: {args.name} has leading or trailing whitespace; sealing it verbatim.")
    seal(args.name, first.encode())
    print(f"{args.name}: sealed. Verify with 'show' or the next backup run.")


def show(args):
    require(os.geteuid() == 0, "Run with sudo on the installed crow.")
    names = CREDENTIALS if args.only is None else (args.only,)
    for name in names:
        require(sealed(name), f"No sealed {name} credential; run 'generate' first.")
        value = decrypt(name, SEALED_STORE / name)
        require(b"\n" not in value, f"Sealed {name} contains a newline; refusing to print.")
        print(f"{name}: {value.decode()}")


def status():
    for name in CREDENTIALS:
        print(f"{name}: {'sealed' if sealed(name) else 'missing'}")
    print("Provision missing credentials with 'sudo sys setup-backup-keys generate'.")


def service(args):
    """Compose the runtime repository settings from unsealed credentials."""
    credentials = Path(os.environ["CREDENTIALS_DIRECTORY"])
    runtime = Path(os.environ["RUNTIME_DIRECTORY"])

    def read(name):
        value = (credentials / name).read_text()
        require(value != "" and "\n" not in value and "\r" not in value, f"Invalid {name} credential.")
        return value

    endpoint = read("restic-repository-endpoint").strip()
    username = read("restic-repository-username").strip()
    restic_password = read("restic-password")
    server_password = read("rest-server-password")
    parts = urlsplit(endpoint)
    require(parts.scheme in ("http", "https"), f"Unsupported repository endpoint scheme: {parts.scheme!r}")
    require(parts.username is None and parts.password is None,
            "The repository endpoint must not embed user credentials.")
    require(parts.hostname, "The repository endpoint must include a host.")
    require(not parts.query and not parts.fragment,
            "The repository endpoint must not include a query or fragment.")
    repository = (f"rest:{parts.scheme}://"
                  f"{quote(username, safe='')}:{quote(server_password, safe='')}"
                  f"@{parts.netloc}{parts.path}")
    for name, data in (("restic-password", restic_password.encode()), ("repository", repository.encode())):
        staged = runtime / f".{name}"
        staged.write_bytes(data)
        os.chmod(staged, 0o600)
        os.replace(staged, runtime / name)


def main():
    parser = argparse.ArgumentParser(description="Provision Crow's TPM-sealed restic backup credentials.")
    commands = parser.add_subparsers(dest="command")
    generated = commands.add_parser("generate", help="generate and seal any missing credentials")
    generated.add_argument("--only", choices=CREDENTIALS, default=None)
    generated.set_defaults(handler=generate)
    entered = commands.add_parser("enter", help="seal a known value, e.g. the TrueNAS basic-auth password")
    entered.add_argument("name", choices=CREDENTIALS)
    entered.set_defaults(handler=enter)
    shown = commands.add_parser("show", help="decrypt and print sealed credentials")
    shown.add_argument("--only", choices=CREDENTIALS, default=None)
    shown.set_defaults(handler=show)
    compose = commands.add_parser("service", help="compose runtime settings (run by systemd)")
    compose.set_defaults(handler=service)
    parser.set_defaults(handler=lambda args: status())
    args = parser.parse_args()
    try:
        args.handler(args)
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        sys.exit(f"crow-backup-keys: {error}")


if __name__ == "__main__":
    main()
