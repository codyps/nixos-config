"""Initialize local account hashes and persist successful PAM password changes."""
import argparse
import fcntl
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

ACCOUNTS = ("root", "cody")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def private_file(path):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o077,
            f"Expected a root-owned private regular file: {path}")
    return path.read_bytes()


def validate_hash(value):
    require(value and b"\n" not in value and b":" not in value and b"\0" not in value,
            "Invalid password hash record.")
    # Locked passwords are also valid user/admin state and must survive rebuilds.
    require(value.startswith((b"$y$", b"$6$", b"!", b"*")), "Unsupported password hash format.")
    return value


def publish(path, value):
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".password-", delete=False) as stream:
        staged = Path(stream.name)
        try:
            os.chmod(staged, 0o600)
            stream.write(validate_hash(value) + b"\n")
            stream.flush()
            os.fsync(stream.fileno())
            os.replace(staged, path)
            directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            staged.unlink(missing_ok=True)


def initialize(store, passwords):
    # Read and validate all inputs before writing anything. Never overwrite a
    # current hash with a stale initial password when installation is retried.
    pending = []
    for account in ACCOUNTS:
        destination = store / account
        if destination.exists() or destination.is_symlink():
            validate_hash(private_file(destination).rstrip(b"\n"))
            continue
        password = private_file(passwords / account)
        require(len(password) >= 20 and all(c in b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-" for c in password),
                "Invalid generated account password.")
        result = subprocess.run(["mkpasswd", "--method=yescrypt", "--stdin"],
                                input=password + b"\n", stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        require(result.returncode == 0, "Password hashing failed; output withheld.")
        pending.append((destination, validate_hash(result.stdout.strip())))
    for destination, value in pending:
        publish(destination, value)


def save_changed_password(store, shadow, account):
    require(account in ACCOUNTS, "Account is not managed by this password store.")
    records = [line.split(b":") for line in shadow.read_bytes().splitlines()
               if line.split(b":", 1)[0] == account.encode()]
    require(len(records) == 1 and len(records[0]) == 9, "Missing or malformed shadow entry.")
    publish(store / account, records[0][1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    init = sub.add_parser("initialize", help="Install initial hashes without replacing existing hashes")
    init.add_argument("--root", type=Path, default=Path("/"))
    init.add_argument("--password-dir", type=Path, required=True)
    sub.add_parser("pam-save", help="Persist the hash after a successful passwd change")
    args = parser.parse_args()
    require(os.geteuid() == 0, "Run as root.")
    os.umask(0o077)
    root = args.root if args.command == "initialize" else Path("/")
    persist = root / "persist"
    mounted = subprocess.run(["mountpoint", "--quiet", str(persist)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    require(mounted.returncode == 0, "Mount /persist before provisioning account passwords.")
    store = persist / "shadow.d"
    require(not store.is_symlink(), "Password store must not be a symlink.")
    store.mkdir(mode=0o700, exist_ok=True)
    require(store.stat().st_uid == 0, "Password store must be root-owned.")
    os.chmod(store, 0o700)
    descriptor = os.open(store / ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.command == "initialize":
            initialize(store, args.password_dir)
        else:
            require(os.environ.get("PAM_TYPE") == "password", "Expected a PAM password update.")
            account = os.environ.get("PAM_USER", "")
            if account in ACCOUNTS:
                save_changed_password(store, Path("/etc/shadow"), account)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        sys.exit(str(error))
