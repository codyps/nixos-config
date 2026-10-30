"""Idempotent initrd credential provisioning and attended LUKS TPM enrollment."""

import argparse
import fcntl
import getpass
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import time

PLAIN_STORE = None
STORE = None
EFI = Path("/sys/firmware/efi/efivars")
EFI_GUID = "8be4df61-93ca-11d2-aa0d-00e098032b8c"
SYS_DEV_BLOCK = Path("/sys/dev/block")


def device_is_within_mapping(device_number, mapping_number, ancestors=frozenset()):
    """Every backing-device branch must pass through the expected LUKS mapping."""
    if device_number == mapping_number:
        return True
    if device_number in ancestors:
        return False
    device = SYS_DEV_BLOCK / f"{os.major(device_number)}:{os.minor(device_number)}"
    try:
        slaves = list((device / "slaves").iterdir())
        # A plain partition/disk outside the mapping is not encrypted by it.
        if not slaves:
            return False
        for slave in slaves:
            major, minor = map(int, (slave / "dev").read_text().strip().split(":"))
            if not device_is_within_mapping(os.makedev(major, minor), mapping_number,
                                            ancestors | {device_number}):
                return False
        return True
    except (OSError, ValueError):
        return False


def run(*args):
    # Capture tool output: credentials and private key material must not be logged.
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def verify_state_backing(config):
    source = run("findmnt", "--evaluate", "-n", "-o", "SOURCE", "--target", config["stateDirectory"]).decode().strip()
    mapper = f"/dev/mapper/{config['mapperName']}"
    # Direct filesystems (including Btrfs subvolumes) retain the original check.
    if source.startswith("/dev/"):
        require(device_is_within_mapping(os.stat(source.split("[", 1)[0]).st_rdev, os.stat(mapper).st_rdev),
                "The state directory must be on the configured encrypted root mapping.")
        return
    fstype = run("findmnt", "-n", "-o", "FSTYPE", "--target", config["stateDirectory"]).decode().strip()
    require(fstype == "zfs", "Unsupported state filesystem; expected the configured encrypted root.")
    pool = source.split("/", 1)[0]
    # Accept only a single disk vdev, optionally layered through LVM. Reject
    # mirrors, caches, logs and additional disks rather than overlooking data
    # outside the pinned mapping. zpool -P emits absolute leaf device paths.
    rows = [line.split() for line in run("zpool", "list", "-vHP", pool).decode().splitlines() if line.strip()]
    require(len(rows) == 2 and rows[0][0] == pool and rows[1][0].startswith("/dev/"),
            "State ZFS pool must have exactly one disk on the configured encrypted root.")
    require(device_is_within_mapping(os.stat(rows[1][0]).st_rdev, os.stat(mapper).st_rdev),
            "State pool is not exclusively on the configured encrypted root.")


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
    verify_state_backing(config)
    return config


def credential_available(name):
    return any((directory / name).exists() or (directory / name).is_symlink()
               for directory in (PLAIN_STORE, STORE))


def secure_boot_ready():
    for name, expected in [("SecureBoot", 1), ("SetupMode", 0)]:
        try:
            data = (EFI / f"{name}-{EFI_GUID}").read_bytes()
        except FileNotFoundError:
            return False
        require(len(data) == 5, "Malformed Secure Boot firmware variable.")
        if data[4] != expected:
            return False
    return True


def prepare_install(config, work):
    """Stage only available ciphertext; never silently downgrade an enrolled host."""
    state = Path(config["stateDirectory"])
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    marker = state / "provisioning-ready"
    staged = state / "initrd-credentials"
    require(not staged.is_symlink(), "Initrd credential directory must not be a symlink.")
    staged.mkdir(mode=0o700, exist_ok=True)
    staged.chmod(0o700)
    previous = json.loads(private_input(marker).read_text()) if marker.exists() else None
    # Adopt existing deployments without a marker, preserving their identities.
    existing = [name for name in ("ssh-host-key", "wifi", "tailscale-state")
                if (STORE / name).exists() or (STORE / name).is_symlink()]
    provisioned = previous is not None or bool(existing) or (STORE / "ssh-host-key.pub").exists()
    ready = (config.get("rootVolumeKeyId") is not None
             and os.uname().nodename == config["hostName"] and secure_boot_ready())
    if not ready:
        require(not provisioned, "Provisioned unlock state exists: boot the installed, pinned host with Secure Boot enabled before rebuilding.")
        require(not any(staged.iterdir()), "Unexpected staged credentials on an unprovisioned host.")
        print("Unlock provisioning deferred: console passphrase only until the pinned host boots with Secure Boot enabled.")
        return
    preflight(config, require_current_generation=False)
    if previous:
        require(previous["rootVolumeKeyId"] == config["rootVolumeKeyId"],
                "Root volume identity changed; explicit recovery/migration is required.")
    requested = []
    if config.get("remoteUnlock"):
        requested.append("ssh-host-key")
        for name, enabled in [("wifi", config["wifi"]), ("tailscale-state", config.get("tailscale"))]:
            known = name in existing or (previous and name in previous["credentials"])
            available = (PLAIN_STORE / name).exists() or (PLAIN_STORE / name).is_symlink()
            if enabled and (known or available):
                requested.append(name)
            elif enabled:
                print(f"Optional {name} recovery awaits credentials; wired SSH remains available.")
        for name in requested:
            if name in existing or (previous and name in previous["credentials"]):
                require((PLAIN_STORE / name).exists() or (STORE / name).exists(),
                        f"Previously provisioned {name} is missing; restore its credential backup.")
        credentials(argparse.Namespace(ssh_key_file=None, wifi_file=None,
                    ssh_only="wifi" not in requested, tailscale="tailscale-state" in requested), work)
    # Record readiness before copying: an interrupted publication must fail closed
    # on a later insecure boot, rather than reverting to initial provisioning.
    record = work / "provisioning-ready"
    record.write_text(json.dumps({"rootVolumeKeyId": config["rootVolumeKeyId"],
                                 "credentials": sorted(set(requested + (previous["credentials"] if previous else existing)))}))
    publish(record, marker)
    for name in requested:
        publish(private_input(STORE / name), staged / name)
    for entry in staged.iterdir():
        if entry.name not in requested:
            require(entry.is_file() and not entry.is_symlink(), "Unexpected staged credential entry.")
            entry.unlink()
    print("Unlock credentials staged. Boot-file installation can now update the measured-boot policy.")


def publish_credentials(config, esp):
    """Use encrypted EFI companion files so unchanged UKIs need no regeneration."""
    staged = Path(config["stateDirectory"]) / "initrd-credentials"
    destination = esp / "loader/credentials"
    destination.mkdir(parents=True, exist_ok=True)
    for name in ("ssh-host-key", "wifi", "tailscale-state"):
        source = staged / name
        target = destination / f"{name}.cred"
        if source.exists():
            publish(private_input(source), target)
        else:
            target.unlink(missing_ok=True)


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
                              ssh_only=not config["wifi"] or not credential_available("wifi"), tailscale=True)
    credentials(args, work)
    print(f"Separate initrd Tailscale node {config['tailscaleHostName']} sealed. Rebuild boot files before testing.")


def recovery_slots(metadata):
    token_slots = {slot for token in metadata["tokens"].values() for slot in token["keyslots"]}
    return sorted(set(metadata["keyslots"]) - token_slots)


def policy_pcrs(config):
    try:
        policy = json.loads(Path(config["policy"]).read_text())
        return {item["pcr"] for item in policy["pcrValues"]}
    except (ValueError, KeyError, TypeError) as error:
        raise RuntimeError("Invalid measured policy metadata; rebuild a complete policy before enrollment.") from error


def verify_policy(config):
    expected = set(config["pcrs"])
    actual = policy_pcrs(config)
    require(expected <= actual,
            f"Measured policy covers PCRs {sorted(actual)}, expected {sorted(expected)}. Prepare boot files and reboot before enrollment.")


def prediction_log(config):
    return json.loads(run(config["pcrlock"], "log", "--json=short", *config["predictionArgs"]))


def measurements_ready(config):
    pcrs = {entry["pcr"]: entry for entry in prediction_log(config)["pcrs"]}
    return all(pcr in pcrs and all(pcrs[pcr].get(flag) is True for flag in
               ("hashMatchesEventLog", "allEventsMatched", "noMissingComponents")) for pcr in config["pcrs"])


def retain_booted_measurement(config, work):
    """Retain existing approval only when it explains the verified current boot."""
    if 4 not in config["pcrs"]:
        return
    log = prediction_log(config)
    require(any(p["pcr"] == 4 and p.get("hashMatchesEventLog") is True for p in log["pcrs"]),
            "PCR 4 does not match its event log; refusing measurement retention.")
    hashes = {e["sha256"] for e in log["log"] if e["pcr"] == 4 and "sha256" in e}
    directory = Path(config["pcrlockDirectory"]) / "635-lanzaboote.pcrlock.d"
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / "booted.pcrlock"
    selected = None
    for source in sorted(directory.glob("*.pcrlock")):
        records = json.loads(source.read_text())["records"]
        # Lanzaboote defines one PCR 4 PE measurement per variant. Never create
        # new approval by copying an unknown hash out of the current event log.
        if len(records) == 1 and records[0]["pcr"] == 4 and any(
                d["hashAlg"] == "sha256" and d["digest"] in hashes for d in records[0]["digests"]):
            selected = source.read_bytes()
            break
    if selected is None:
        target.unlink(missing_ok=True)
        print("No existing approved UKI measurement matches this boot; policy preparation may require a reboot.")
    else:
        staged = work / "booted.pcrlock"
        staged.write_bytes(selected)
        publish(staged, target)


def update_policy(config):
    if not measurements_ready(config):
        metadata = json.loads(run("cryptsetup", "luksDump", "--dump-json-metadata", config["disk"]))
        require(not any(t.get("type") == "systemd-tpm2" for t in metadata["tokens"].values()),
                "An enrolled disk has unmatched boot measurements; policy left unchanged. Recover approved measurements before updating.")
        print("Measured policy deferred: boot files installed, but this boot is not fully recognized. Reboot and rerun sudo sys setup-luks-tpm-unlock --prepare-boot. No reduced policy was created.")
        return
    # Validate before touching the TPM; make-policy repeats the same strict check.
    run(config["pcrlock"], "predict", "--strict=yes", *config["predictionArgs"])
    run(config["pcrlock"], "make-policy", "--strict=yes", *config["predictionArgs"], f"--policy={config['policy']}")
    verify_policy(config)
    print("Measured policy updated with every configured PCR.")


def enroll_disk(config, work):
    require(config["diskUnlock"], "Enable boot.secureUnlock.tpmUnlock.enable, rebuild boot files, then reboot first.")
    require(run(config["pcrlock"], "is-supported").strip() == b"yes", "pcrlock is unsupported.")
    require(Path(config["policy"]).is_file(), "No pcrlock policy. Run sudo sys setup-luks-tpm-unlock --prepare-boot, reboot, then rerun enrollment.")
    verify_policy(config)
    run(config["pcrlock"], "predict", "--strict=yes", *config["predictionArgs"])
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


def status(config):
    """Check each stage independently without modifying state."""
    ready = True

    def check(label, action, hint):
        nonlocal ready
        try:
            require(action(), hint)
            print(f"OK    {label}")
        except (OSError, RuntimeError, ValueError, KeyError, TypeError, subprocess.CalledProcessError):
            ready = False
            print(f"TODO  {label}: {hint}")

    check("Installed host", lambda: os.uname().nodename == config["hostName"], "Run on the installed host.")
    check("Local volume pin", lambda: config.get("rootVolumeKeyId") is not None, "Provision this host's pinned hardware inventory.")
    check("Secure Boot", secure_boot_ready, "Enable Secure Boot, leave Setup Mode and reboot.")
    check("TPM device", lambda: Path("/dev/tpmrm0").exists(), "TPM resource manager unavailable.")
    check("Current generation booted", lambda: Path("/run/booted-system").resolve() == Path("/run/current-system").resolve(), "Reboot into the current generation.")
    check("Encrypted state backing", lambda: verify_state_backing(config) is None, "State must be on the configured encrypted root; run with sudo.")
    check("TPM unlock configured", lambda: config["diskUnlock"], "Enable tpmUnlock, rebuild and reboot.")
    check("pcrlock support", lambda: run(config["pcrlock"], "is-supported").strip() == b"yes", "Check TPM support and root access.")
    check("Provisioning record", lambda: (Path(config["stateDirectory"]) / "provisioning-ready").is_file(), "Run sys setup-luks-tpm-unlock --prepare-boot.")
    check("Measured boot policy", lambda: Path(config["policy"]).is_file(), "Prepare boot files and reboot before enrollment.")
    try:
        print(f"INFO  Policy PCR coverage: actual {sorted(policy_pcrs(config))}; required {sorted(config['pcrs'])}")
    except (OSError, ValueError, KeyError, TypeError, RuntimeError):
        pass
    check("Required policy PCR coverage", lambda: verify_policy(config) is None,
          "Policy must include every configured PCR; prepare boot files and reboot.")
    check("Current boot measurements", lambda: measurements_ready(config),
          "Boot measurements do not fully match approved definitions; reboot or repair definitions.")
    for name, enabled in (("ssh-host-key", config.get("remoteUnlock")), ("wifi", config.get("wifi")), ("tailscale-state", config.get("tailscale"))):
        if enabled:
            check(f"Recovery credential {name}", lambda name=name: (STORE / name).is_file(), "Provision recovery credentials, then prepare boot files; optional for TPM unlock.")
            if config.get("esp"):
                check(f"Published recovery credential {name}",
                      lambda name=name: (STORE / name).read_bytes() == (Path(config["esp"]) / "loader/credentials" / f"{name}.cred").read_bytes(),
                      "Prepare boot files to publish the current sealed credential.")
    def metadata():
        return json.loads(run("cryptsetup", "luksDump", "--dump-json-metadata", config["disk"]))
    check("Recovery passphrase slot", lambda: bool(recovery_slots(metadata())), "No token-free recovery slot, or metadata inaccessible; run with sudo.")
    check("TPM pcrlock token", lambda: any(t.get("type") == "systemd-tpm2" and t.get("tpm2_pcrlock") for t in metadata()["tokens"].values()), "Run sys setup-luks-tpm-unlock after boot preparation and reboot.")
    print("Test an unattended cold boot separately; token presence does not prove automatic unlock.")
    return ready


def prepare_boot(config):
    require(config["diskUnlock"], "Enable tpmUnlock and install that generation first.")
    require(config.get("rootVolumeKeyId") is not None, "Provision the pinned volume identity before preparing boot files.")
    preflight(config)
    # The existing hook handles credential staging, UKI signing and PCR policy.
    subprocess.run(["/run/current-system/bin/switch-to-configuration", "boot"], check=True)
    print("Boot files prepared. Reboot, then rerun sys setup-luks-tpm-unlock.")


def resolve_volume_pin(config):
    if config.get("rootVolumeKeyIdFile"):
        pin = json.loads(Path(config["rootVolumeKeyIdFile"]).read_text())
        require(pin is None or isinstance(pin, str) and re.fullmatch(r"[0-9a-f]{64}", pin), "Invalid local root volume pin.")
        config["rootVolumeKeyId"] = pin


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path("/etc/secure-unlock.json"))
    commands = parser.add_subparsers(dest="command", required=True)
    creds = commands.add_parser("credentials", help="Seal or verify initrd SSH/Wi-Fi credentials")
    creds.add_argument("--wifi-file", type=Path)
    creds.add_argument("--ssh-key-file", type=Path, help="Import an existing key into the configured credential store; otherwise reuse or generate once")
    creds.add_argument("--ssh-only", action="store_true", help="Provision Ethernet SSH without Wi-Fi credentials")
    commands.add_parser("prepare-install", help="Provision available credentials when Secure Boot is ready, otherwise stage console-only boot")
    publish_cmd = commands.add_parser("publish-credentials", help="Install staged encrypted EFI companion credentials")
    publish_cmd.add_argument("--esp", type=Path, required=True)
    commands.add_parser("retain-booted-measurement", help="Retain an existing approved measurement matching this boot")
    commands.add_parser("update-policy", help="Strictly update policy, or defer unenrolled first provisioning until reboot")
    commands.add_parser("status", help="Report all unlock provisioning stages without changes")
    disk_cmd = commands.add_parser("enroll-disk", help="Verify recovery passphrase and add a TPM LUKS token")
    disk_options = disk_cmd.add_mutually_exclusive_group()
    disk_options.add_argument("--status", action="store_true")
    disk_options.add_argument("--prepare-boot", action="store_true", help="Provision credentials and install signed measured boot files, then reboot before enrollment")
    commands.add_parser("enroll-tailscale", help="Register and seal a separate non-expiring initrd Tailscale node")
    args = parser.parse_args()
    os.umask(0o077)
    require(not (args.command == "credentials" and args.ssh_only and args.wifi_file),
            "--ssh-only cannot be combined with --wifi-file.")
    config = json.loads(args.config.read_text())
    try:
        resolve_volume_pin(config)
    except (OSError, ValueError, RuntimeError):
        if args.command != "status" and not getattr(args, "status", False):
            raise
        config["rootVolumeKeyId"] = None

    if args.command == "credentials" and not config["wifi"]:
        require(not args.wifi_file, "Enable Wi-Fi in the host configuration before supplying credentials.")
        args.ssh_only = True
    global PLAIN_STORE, STORE
    PLAIN_STORE = Path(config["stateDirectory"]) / "credstore"
    STORE = Path(config["stateDirectory"]) / "credstore.encrypted"
    if args.command == "credentials":
        args.tailscale = config.get("tailscale", False) and credential_available("tailscale-state")
        args.ssh_only = args.ssh_only or (not args.wifi_file and not credential_available("wifi"))
    if args.command == "status" or getattr(args, "status", False):
        sys.exit(0 if status(config) else 1)
    if getattr(args, "prepare_boot", False):
        prepare_boot(config)
        return
    require(os.geteuid() == 0, "Run with sudo on the installed host.")
    if args.command not in ("prepare-install", "publish-credentials", "retain-booted-measurement", "update-policy"):
        require(config.get("rootVolumeKeyId") is not None, "Pin the root volume identity and reboot before provisioning unlock state.")
        preflight(config, require_current_generation=args.command == "enroll-disk")
    with open("/run/secure-unlock-setup.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with tempfile.TemporaryDirectory(prefix="secure-unlock-", dir="/run") as directory:
            work = Path(directory)
            if args.command == "retain-booted-measurement":
                retain_booted_measurement(config, work)
            elif args.command == "update-policy":
                update_policy(config)
            elif args.command == "prepare-install":
                prepare_install(config, work)
            elif args.command == "publish-credentials":
                prepare_install(config, work)
                publish_credentials(config, args.esp)
            elif args.command == "credentials":
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
        message = f"{Path(error.cmd[0]).name} failed (exit {error.returncode}); secret output suppressed. Run sudo sys unlock-status." if isinstance(
            error, subprocess.CalledProcessError) else str(error)
        sys.exit(message)
