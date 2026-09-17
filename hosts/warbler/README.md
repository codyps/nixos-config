# Warbler

Inspected at `nixos@nixos.bed.einic.org`: x86_64 AMD, 64 GB RAM, UEFI,
TPM 2.0 (`systemd-pcrlock is-supported` returned `yes`), Secure Boot disabled.
The installer currently uses Wi-Fi `wlp3s0` (rtw89_8852ae); `eno1` is unplugged.

## Physical firmware checklist

User-supplied `lshw` identifies an **HP EliteDesk 805 G8 Desktop Mini PC**,
SKU `63C34UC#ABA`, motherboard `8881`, BIOS **T26 02.14.00**, dated
2024-11-21. This records the installed version, not a claim that it is current.
BIOS administrator authentication is enabled; have that password and local
keyboard/display access before provisioning. No firmware changes have been made.

HP's [commercial BIOS guide, June 2023](https://ftp.hp.com/pub/caps-softpaq/cmit/whitepapers/HPBIOSSetup.pdf)
explicitly includes the 805 G8 DM (page 8). It describes a superset of settings;
the following menu locations must still be checked on this T26 firmware:

| Location | Warbler requirement / action |
| --- | --- |
| F10 during startup | Enter firmware setup using administrator credentials. |
| Security → TPM submenu | `TPM Device`: available; `TPM State`: enabled. Do not schedule a TPM clear. |
| Security → BIOS Sure Start | Review `Sure Start Secure Boot Keys Protection` before custom-key enrollment. It backs up and restores keys; plan to disable this specific protection during enrollment, not unrelated firmware protections. Confirm custom keys survive reboot before considering re-enabling it. |
| Security → Secure Boot Configuration | Secure Boot must ultimately enforce Warbler's enrolled signing keys. Merely switching it off does not prove Setup Mode. |
| Advanced → boot options | Use the NVMe's UEFI boot entry after installation. This model family is UEFI-only; no legacy/CSM setup is needed. |

Menu references: HP guide pages 23–26 and 35. These are desired settings,
not a readback of the current firmware configuration.

**Enrollment checkpoint:** the exact safe Setup Mode operation on T26 02.14.00
is not yet verified. Prefer a platform-key-only removal if the firmware offers
one. Do not blindly use an all-key clearing action: it can also remove `dbx`,
the revoked-signature database. If the UI only offers wholesale clearing or
key import, stop and establish a backed-up, dbx-preserving enrollment procedure
before proceeding. Do not restore factory keys after enrolling Warbler's keys.
These cautions follow the [Lanzaboote enrollment guide](https://nix-community.github.io/lanzaboote/getting-started/enable-secure-boot.html).

After enrollment, cold boot and verify Secure Boot enabled in user mode,
Setup Mode disabled, the intended signing keys present, and the revocation
database retained. Then follow credential sealing and optional disk enrollment
below. Firmware/TPM changes after sealing can require recovery and resealing;
keep the LUKS passphrase and encrypted secret backups available.

Wi-Fi must remain enabled for initrd networking. Firmware PXE/Wi-Fi boot is not
required: the Linux initrd performs association. CPU virtualization is needed
for KVM tests, not for LUKS or impermanence; the successful physical-host KVM
test already establishes that it was usable. Leave the SATA disk untouched.

Disko targets the SK hynix 512 GB NVMe at `/dev/nvme0n1`.
Reconfirm its model and capacity before installation: device enumeration can
change if hardware is added. No hardware serial numbers are recorded here.
The TEAM 4 TB SATA SSD and installer USB are not in the disk configuration.
The NVMe gets a 2 GiB unencrypted EFI partition and a LUKS2 container with
Btrfs sibling subvolumes `root`, `nix`, `persist`, and `home`, mounted at `/`,
`/nix`, `/persist`, and `/home`. The systemd initrd deletes and recreates only
`root` after LUKS unlock and before mounting `/`; it is not tmpfs. Nested root
subvolumes are deleted too, with no old-root retention. A reset failure blocks
the root mount. This adapts the [impermanence Btrfs example](https://github.com/nix-community/impermanence#system-setup)
to systemd initrd. `/var/lib`, `/var/log`, `/var/db`, `/root`, and machine-id
persist; other root changes disappear. Swap is RAM-only zram.

Lanzaboote signs boot artifacts. The EFI partition cannot be encrypted in this
design; all persistent OS data is inside LUKS. Signing keys stay under
`/persist/var/lib/sbctl` and are never copied into the initrd.

The normal configuration pins `cryptroot` with systemd's `fixate-volume-key=`
in the signed initrd. This applies to both passphrase and TPM unlock, before
the Btrfs root-reset service can mount anything. `warbler.rootVolumeKeyId` is
the public HMAC-SHA256 identity of the installed volume, derived from its
volume key and the string `cryptsetup:cryptroot:<LUKS UUID>`; it is not a key
or the digest stored in the LUKS header. Changing the volume key, UUID, or
mapper name requires a new pin. Changing the recovery password does not.

`warbler-bootstrap` explicitly sets this identity to null and disables remote
and TPM disk unlock. Use it only for attended installation of a new volume.
After reformatting, obtain the new identity on the trusted installed system
and update `warbler.rootVolumeKeyId` before building the normal configuration.
The option defaults to `null`; the explicit setting in `configuration.nix`
retains the known identity of the current installation. Never automatically
learn the expected identity from a disk during boot. An unpinned configuration
cannot enable remote or TPM unlock. Pinning authenticates volume identity,
not every filesystem block or its freshness.

On the trusted installed system (including `warbler-bootstrap`), run:

```sh
sudo warbler-root-volume-key-id
```

Or run directly from this checkout on Linux, without installing the command:

```sh
sudo nix run path:.#warbler-root-volume-key-id
# Automation with an existing passphrase file:
sudo nix run path:.#warbler-root-volume-key-id -- --key-file /run/warbler-luks-password
```

The package includes Python and libcryptsetup; no system Python or cryptsetup
installation is needed. This command operates on Linux LUKS devices.

For other devices, use the [general LUKS identity command](../../docs/luks-volume-key-id.md)
with an explicit encrypted device and target mapper name:

```sh
sudo nix run path:.#luks-volume-key-id -- --device /dev/sdb2 --name data
```

Enter the LUKS recovery passphrase. The command prints just the 64-character
public ID to stdout; copy it into `warbler.rootVolumeKeyId` in
`hosts/warbler/configuration.nix`. It reads the configured LUKS device and
derives the ID for mapper name `cryptroot`, without opening a mapping,
changing the header, or writing the raw volume key to a file. The derivation
matches [systemd's volume-key identity](https://github.com/systemd/systemd/blob/main/src/shared/cryptsetup-util.c).
For provisioning automation with an existing passphrase file in RAM:

```sh
sudo warbler-root-volume-key-id --key-file /run/warbler-luks-password
```

Use `--device /dev/disk/by-partlabel/disk-system-crypt` to override the device
when needed. From a checkout on Linux with Python 3 and libcryptsetup installed,
the equivalent command is
`sudo python3 scripts/luks-volume-key-id.py --device /dev/disk/by-partlabel/disk-system-crypt --name cryptroot`.
Run this after formatting and before enabling remote or TPM unlock; never
learn a replacement pin automatically at boot.

## Unlocking and TPM credentials

`ssh -t -p 2222 root@<warbler-ip>` authenticates with `nixos/ssh-auth.nix` keys
and presents the LUKS passphrase prompt. Use the actual DHCP address or arrange
a reservation/DNS entry; this configuration does not create DNS records.
Stage 2 SSH uses port 22 and a separate persistent host key. Both root and cody
accept authorized SSH keys; cody has passwordless sudo. Account passwords are
locked. The LUKS passphrase is independent of SSH account authentication.

Early Wi-Fi and SSH **always require TPM-encrypted credentials**, even when
`warbler.tpmUnlock.enable = false` (the default). Only these ciphertext files
are appended to the initrd at installation/rebuild time:

| Source on encrypted storage | Credential name | Consumer |
| --- | --- | --- |
| `/persist/credstore.encrypted/wifi` | `wifi` | wpa_supplicant in both boot stages |
| `/persist/credstore.encrypted/ssh-host-key` | `ssh-host-key` | initrd sshd only |

systemd `LoadCredentialEncrypted` decrypts into private runtime memory. There
is no plaintext fallback and no dependency on an encrypted-root host secret.
Use explicit `--with-key=tpm2`, **not** `auto-initrd` (which can use a null key
on a machine without a TPM). Provision on warbler itself after booting the
installed, Secure Boot enabled system. The documented credential policy binds
PCR 7: it checks the Secure Boot policy/authority, not the precise kernel or
initrd. It is separate from Lanzaboote's pcrlock policy for disk auto-unlock;
`systemd-creds` does not provide the same pcrlock integration. Anyone able to
execute code under an accepted policy may be able to decrypt these credentials.

Changes to firmware Secure Boot keys/policy or clearing/replacing the TPM may
require resealing. A TPM/policy failure disables remote unlocking, including
SSH over Ethernet. The local-console LUKS passphrase remains usable. Keep it
and a separately encrypted offline backup of the original Wi-Fi configuration,
initrd SSH host key, and signing keys; TPM ciphertext alone cannot recover after
TPM loss. No scheme relying
solely on that TPM can provide remote recovery after the TPM is lost.

## Remote installation from this Mac

`scripts/warbler-install.py` automates the installer-side work over the existing
`nixos@nixos.bed.einic.org` SSH connection. It uses the live host to build the
x86_64 bootstrap system. There is no need for an interactive shell on the other,
store-only builder. Follow **step 1 below** first (backups, BIOS credentials,
local console and Ethernet ready); then use this workflow instead of manual
steps 2–4. The live installer may stay connected over Wi-Fi while installation
runs, but the first installed bootstrap boot requires Ethernet.

From this checkout on the Mac:

```sh
python3 scripts/warbler-install.py prepare
python3 scripts/warbler-install.py check
python3 scripts/warbler-install.py build
python3 scripts/warbler-install.py install
```

- `prepare` captures `apple-password-gen` output without displaying it and
  generates RSA-4096 PK, KEK, and db keys/certificates with local OpenSSL. It
  checks key/certificate matches and uses sbctl-compatible PKCS#8 keys. Repeat
  runs validate and retain the existing bundle, never silently rotate it.
  It also creates a separate Ed25519 stage-2 SSH/SOPS identity under `ssh/`.
  Older bundles gain that identity on `prepare` without rotating their LUKS
  password or signing keys. Partial SSH identities are rejected, not replaced.
- Local storage defaults to `~/.local/share/warbler-install`: `luks-password`
  contains the exact password bytes, and `sbctl/` contains `GUID` and
  `keys/{PK,KEK,db}/`. Directories are private and files are mode 0600. A
  defensive `.gitignore` ignores everything in the bundle. **The bundle must
  remain outside this checkout:** Git ignore rules do not prevent `path:.`
  from importing ignored files into `/nix/store`. The tool rejects in-checkout
  secret paths. `--secrets-dir /absolute/external/path` overrides the location.
- These local files are plaintext, not a password-manager entry or SOPS
  archive. Protect the Mac's disk with encryption and make a separately
  encrypted offline backup before installing. Retrieve the password privately
  from the local file when the console/SSH LUKS prompt needs it; do not paste it
  into commands, logs, Git, or this conversation.
- `check` validates the bundle and performs read-only host/disk checks. It
  requires existing trusted SSH host keys, key authentication, and passwordless
  sudo. It displays model/capacity, not hardware serial numbers.
- `install` sends a source-only snapshot (tracked plus nonignored untracked
  files), builds `warbler-bootstrap` and disko **without any secrets**, and
  rechecks the expected empty NVMe. It then requires the exact typed erase
  confirmation. Only afterward are secrets sent over SSH to a separate,
  root-only live-RAM directory, outside the flake source. Disko reads the
  password at runtime; the keys are copied into encrypted `/persist` before
  bootloader signing. The local password is not a Nix argument or store input.
  The stage-2 SSH host key is installed at `/persist/ssh/ssh_host_ed25519_key`
  before `nixos-install`, so early SOPS secrets can decrypt on first activation.
  `check`, `build`, and `install` require it to match `ssh-host-key.pub` here.
- `build` runs that same source-transfer/build/preflight path but stops before
  confirmation, secret transfer, or disk changes. Use it to validate the remote
  build path safely before the installation window.
- The installer persists the checkout at `/persist/nixos-config`, writes the
  installed sbctl config, cleans up remote temporary secrets on normal exit,
  and **does not reboot or enroll firmware/TPM keys**. If SSH is lost, cleanup
  cannot be guaranteed until the live environment is rebooted. Do not reboot
  or blindly rerun after failure: the disk may be partially installed. This
  fresh-install tool refuses existing partitions rather than guessing a resume
  or reformat procedure.

On successful installation, continue at **step 5** below: first NVMe boot,
BIOS Setup Mode/key enrollment, Secure Boot verification, and only then TPM
credential sealing. Do not regenerate keys in the manual instructions. The
copied checkout retains normal `warbler` settings; `warbler-bootstrap` supplies
temporary forced-off remote/TPM unlock settings without editing the checkout.
The later rebuild to `.#warbler` happens only after credentials exist.

This automates installation preparation, transfer, formatting, and signing—not
the unresolved safe T26 Setup Mode operation. Have someone at the local console
for the firmware steps and first unlock. Local key layout follows
[sbctl's file backend](https://github.com/Foxboron/sbctl/blob/0.18/backend/file.go).

## SOPS identity and adding secrets

Like Robin, Warbler imports sops-nix and uses the persistent stage-2 Ed25519
SSH host key for `sops.age.sshKeyPaths`. `/persist` mounts during initrd, so the
key is available even for `neededForUsers` secrets. No RSA/GPG SSH key or
separately generated age identity is used. The TPM-sealed port-2222 SSH identity
is separate and is never used to decrypt SOPS data.

The public SSH identity is recorded in `hosts/warbler/ssh-host-key.pub`; its age
recipient is `host_warbler` in `.sops.yaml`. The rule for
`hosts/warbler/secrets.yaml` includes that recipient and the existing Cody
administrator recipient. No Robin secrets were shared, and no production
secret file is created until needed. To add one, run from the checkout:

```sh
nix develop --command sops hosts/warbler/secrets.yaml
```

Declare each secret in `hosts/warbler/secrets.nix`, for example:

```nix
sops.secrets.example = {
  sopsFile = ./secrets.yaml;
  # neededForUsers = true; # Only for secrets needed before user creation.
};
```

After installation, compare `ssh-keygen -y -f /persist/ssh/ssh_host_ed25519_key`
with the recorded public key through a trusted connection. Keep the private key
in the external local bundle and its encrypted backup, never in Git or an
initrd. A replacement host key requires updating both the public record and
SOPS recipient, and rewrapping existing files with `sops updatekeys` using an
authorized old/admin identity. Generating a new key alone cannot recover old
secrets. See [sops-nix's SSH/age integration](https://github.com/Mic92/sops-nix).

## Initial provisioning (manual steps and attended firmware checkpoints)

Follow these steps in order; BIOS actions are manual and are not performed by
the TPM helper. Commands below are instructions, not evidence of installation.

1. **Before disk changes — local console / BIOS:** have backups, the BIOS
   administrator password, keyboard/display, an installer USB, and the SSH
   private key corresponding to an authorized key in `nixos/ssh-auth.nix`.
   Plug in Ethernet; bootstrap has no installed Wi-Fi service. Enter F10,
   confirm TPM availability/access and Wi-Fi enabled using the checklist above.
   Leave Secure Boot disabled for the unsigned installer/bootstrap. Do not
   clear the TPM or change Secure Boot keys yet. Save and boot the live USB
   in UEFI mode. If firmware updates are planned, finish them before enrollment
   and recheck settings; this runbook does not prescribe a BIOS update.

2. **Live USB — prepare the checkout:** obtain this checkout on the live host,
   including all uncommitted Warbler files. Enter a root shell (`sudo -i`) and
   `cd` to that checkout. All installer commands below run there as root.
   In the `config` attribute of `hosts/warbler/configuration.nix`, set
   `warbler.remoteUnlock.enable = false` temporarily and keep
   `warbler.tpmUnlock.enable = false`. This omits both encrypted
   initrd credentials and Wi-Fi services until credentials can be sealed against
   the final Secure Boot state. Disk unlocking is local-console only during
   bootstrap; administration after boot is via wired SSH. Use `path:.` in flake
   commands so untracked host files are included.

3. **Live USB — inspect, then format the NVMe:** inspect without displaying
   serial numbers:

   ```sh
   test -d /sys/firmware/efi
   lsblk -o NAME,PATH,SIZE,MODEL,TYPE,FSTYPE,MOUNTPOINTS
   nix build --accept-flake-config --no-link --print-out-paths \
     path:.#nixosConfigurations.warbler.config.system.build.diskoScript
   ```

   Confirm `/dev/nvme0n1` is the intended 512 GB NVMe, not the 4 TB SATA SSD
   or USB. Supply a strong LUKS passphrase in a root-only installer file
   `/tmp/warbler-luks-password` without adding it to Git or the Nix store.

   ```sh
   umask 077
   read -r -s -p 'New LUKS passphrase: ' warbler_passphrase; echo
   printf '%s' "$warbler_passphrase" > /tmp/warbler-luks-password
   unset warbler_passphrase
   ```

   **Destructive boundary:** only after confirming the target and backups,
   execute the exact store path printed by the build above. That executable
   formats and mounts the configured layout at `/mnt`; do not rerun it to
   resume a later step. Nothing on the NVMe is recoverable through this runbook
   after formatting; recovery depends on your backups.

4. **Live USB — generate signing keys, then install:** verify `/mnt`,
   `/mnt/nix`, `/mnt/home`, `/mnt/persist`, and `/mnt/boot` are mounted as
   expected using `findmnt`. Create a root-only `/run/warbler-sbctl-install.conf`
   with an editor (outside the checkout):

   ```yaml
   keydir: /mnt/persist/var/lib/sbctl/keys
   guid: /mnt/persist/var/lib/sbctl/GUID
   ```

   Before running the installation commands below, copy the registered SSH
   key pair from the Mac's external bundle `ssh/` into `/mnt/persist/ssh/`,
   root-owned with directory mode 0700 and file mode 0600. Do not generate a
   different key on the LiveCD: it would not match the SOPS recipient. The
   remote installer performs this step automatically.

   ```sh
   mkdir -p /mnt/persist/var/lib/sbctl
   nix shell --inputs-from path:. nixpkgs#sbctl --command \
     sbctl --config /run/warbler-sbctl-install.conf create-keys
   mkdir -p /mnt/persist/nixos-config
   cp -a . /mnt/persist/nixos-config/
   nixos-install --no-root-passwd --flake path:.#warbler
   ```

   Stop on any failure. Lanzaboote needs these keys before installation signs
   the boot files. The checkout is copied to persistent storage because `/`
   is blanked on boot; keep secret files outside it. Back up signing keys to
   separately encrypted offline storage. Remove the temporary passphrase file
   after successful installation (`rm /tmp/warbler-luks-password`).

5. **First installed boot — BIOS then OS:** reboot, enter F10 if necessary,
   select the NVMe UEFI entry, and keep Secure Boot disabled for this bootstrap
   check. Remove the USB or put NVMe ahead of it. Unlock LUKS at the console.
   From your workstation, SSH as `cody@<wired-ip>`, then `sudo -i` and
   `cd /persist/nixos-config`. Console account passwords are locked; the LUKS
   prompt is not an account login. Verify `hostname` is `warbler`, the expected
   mounts are present, and `bootctl status` identifies the installed bootloader.
   Create `/persist/warbler-sbctl.conf`, root-owned mode 0600, containing:

   ```yaml
   keydir: /persist/var/lib/sbctl/keys
   guid: /persist/var/lib/sbctl/GUID
   ```

   Run `sbctl --config /persist/warbler-sbctl.conf verify` and inspect any
   unsigned-file reports before proceeding. Do not regenerate signing keys.

6. **Second BIOS visit — prepare enrollment:** reboot into F10. Review the
   Sure Start key-protection setting from the checklist; disable that specific
   protection for custom-key enrollment if present. Resolve the T26 Setup Mode
   checkpoint above: do not use wholesale key clearing or factory reset as a
   substitute. Preserve/back up existing public firmware key databases and
   `dbx` before any change. If a safe operation cannot be established, **stop
   here**, leaving the working passphrase-unlocked bootstrap available.
   After the verified Setup Mode operation, save and boot the installed NVMe
   again. Unlock LUKS locally and reconnect over wired SSH.

7. **Installed OS — enroll, then return to BIOS:** in a root shell, confirm
   `sbctl status` reports Setup Mode enabled. Enroll using the existing keys:

   ```sh
   sbctl --config /persist/warbler-sbctl.conf enroll-keys --microsoft
   ```

   Review whether HP firmware certificates also need retaining before running
   enrollment; Microsoft certificates alone are not a backup of all vendor
   keys. Reboot into F10, enable Secure Boot enforcement if not already enabled,
   and save. Do not restore factory keys. Keep the enrollment-time Sure Start
   setting unchanged until custom-key survival is verified. Boot the NVMe and
   unlock locally once more. Verify `bootctl status` reports Secure Boot
   enabled in user mode, `sbctl status` reports Setup Mode disabled, and run
   `sbctl --config /persist/warbler-sbctl.conf verify`. Check the intended keys
   and retained `dbx`; stop if firmware restored or rejected the custom keys.
   Any later attempt to re-enable key protection belongs before sealing, with
   another cold boot and the same checks. No further BIOS changes are needed
   in the normal flow below.

8. **Secure Boot verified — seal credentials:** in a root shell on this
   installed system, create a complete wpa_supplicant
   config in `/run/warbler-wifi.conf` using an editor, with mode 0600:

   ```text
   network={
     ssid="YOUR_SSID"
     psk="YOUR_WIFI_PASSWORD"
   }
   ```

   The installed helper seals it and generates/seals a dedicated initrd SSH
   host key. Run this after rebooting into the current installed generation:

   ```sh
   sudo warbler-tpm-setup credentials --wifi-file /run/warbler-wifi.conf
   ```

   The helper checks Secure Boot, TPM availability, and the encrypted `/persist`
   mount, round-trips both credentials before publishing ciphertext, and prints
   the public SSH fingerprint. Existing credentials are verified and retained
   on repeat runs; omit `--wifi-file` when only checking existing credentials.
   An existing SSH identity is never silently replaced. Supply
   `--ssh-key-file /run/existing-initrd-key` to provision an existing identity
   or reseal it from backup after a TPM/policy change; it must match the saved
   public key. Supply the Wi-Fi file again when resealing after a policy change.

   Record the public fingerprint on the SSH client. The helper removes its
   temporary plaintext files on exit; supplied `/run` inputs disappear on reboot.
   Back up the generated SSH identity to separately encrypted offline storage
   before clearing the TPM (decrypt it on the working host into a private `/run`
   file for backup). Do not put Wi-Fi or SSH private keys in `boot.initrd.secrets`;
   that option only carries the encrypted blobs in this configuration.

9. **Enable remote unlock — rebuild, then cold boot:** in the persisted
   checkout, record the ID from `sudo warbler-root-volume-key-id` in
   `warbler.rootVolumeKeyId`, restore `warbler.remoteUnlock.enable = true` and leave automatic
   disk unlock disabled. Run from `/persist/nixos-config`:

   ```sh
   sudo nixos-rebuild boot --flake path:.#warbler
   ```

   On success, power off and start again with console access available. Unplug
   Ethernet for this test so it proves Wi-Fi works. From your workstation run
   `ssh -t -p 2222 root@<wifi-ip>`. Test Wi-Fi association and port 2222, verify
   the recorded host fingerprint, enter the LUKS passphrase, then verify port
   22 and persistence. This cold-boot test is required; evaluation cannot verify
   the physical radio, firmware measurements, DHCP, or TPM decryption in initrd.
   If it fails, unlock locally and reconnect Ethernet for diagnosis; do not
   clear the TPM or repeat formatting. Keep the preceding bootstrap generation
   available in the boot menu during provisioning only. Before enrolling
   unattended unlock, retire unpinned boot artifacts and exclude their
   measurements from the effective TPM policy; retaining an accepted old
   unpinned generation provides a route around the new volume check.

## Optional automatic disk unlock

This is step 10, only after step 9 succeeds; there is no additional BIOS toggle
for LUKS auto-unlock. In `/persist/nixos-config`, set
`warbler.tpmUnlock.enable = true`, rebuild with `sudo nixos-rebuild boot --flake path:.#warbler`,
and reboot once using the LUKS passphrase. Lanzaboote generates and persists a
managed policy for PCRs 0, 4, and 7; eight boot generations are retained.
Only pinned generations should remain accepted when enrolling. Secure Boot
must enforce the trusted boot artifacts; a pin in a replaceable initrd does
not protect against physical tampering. These are deployment checks, not
properties established by building the configuration.

Then enroll on warbler using the same helper:

```sh
sudo warbler-tpm-setup enroll-disk
```

On success, power off and start again without supplying a passphrase. Verify
stage-2 SSH on port 22 and the persistent files. Keep local console access and
the recovery passphrase until this unattended cold boot succeeds.

The helper prompts once for the existing recovery passphrase and verifies it
against a token-free LUKS slot before adding a TPM token. It verifies that
existing slots remain unchanged. Re-running leaves an existing pcrlock token
alone; enrollment under a different TPM policy requires explicit migration.
Only the configured NVMe LUKS partition is targeted. The helper does not delete
slots, change firmware, refresh the ESP, rebuild NixOS, or reboot. The command
is available in bootstrap configurations too, but requires the measured-boot
configuration to be booted before disk enrollment.
Lanzaboote maintains the disk policy on subsequent bootloader updates. TPM
unlock failure falls back to the LUKS passphrase; remote fallback additionally
requires the separately sealed SSH/Wi-Fi credentials to remain decryptable.
Test both paths before relying on unattended reboots. Do not clear the TPM or
remove the passphrase slot as a test.

## Validation

For an uncommitted checkout use `path:.` so Nix includes the new host files:

```sh
nix eval --raw path:.#nixosConfigurations.warbler.config.system.build.toplevel.drvPath
nix build path:.#nixosConfigurations.warbler.config.system.build.toplevel --no-link
nix build path:.#nixosConfigurations.warbler.config.system.build.diskoScript --no-link
python3 scripts/test-warbler-tpm-setup.py
python3 scripts/test-warbler-install.py
nix eval --impure --json --file scripts/test-warbler-volume-key.nix
nix build path:.#checks.x86_64-linux.luks-volume-key-id --no-link
```

Building does not format disks, install/sign the ESP, enroll credentials, or
activate the configuration. A Linux builder is required on macOS.
The Python tests mock TPM and disk commands; they validate failure handling,
repeat runs, identity preservation, and recovery checks, not physical enrollment.
The Nix pin checks cover manual/TPM configuration, malformed/missing pins,
and the attended bootstrap exception. On Linux, as root with `python3`,
`cryptsetup`, and `systemd-cryptsetup` in PATH, run
`bash scripts/test-warbler-volume-key.sh` to exercise real volume activation
on disposable images under `/run`: correct identity succeeds, substituted
key and UUID fail before mapping. The QEMU test runs this check too and uses
a separate public test volume key and pin for its manual and TPM boots.

## QEMU integration test

Run the VM test through Nix, including when the builder's SSH key forces
`nix-store` and cannot open a shell:

```sh
nix build --accept-flake-config --no-link --print-out-paths -L \
  path:.#checks.x86_64-linux.warbler-vm
```

While the target is running the live CD, use its KVM support as a one-off
builder (requires the existing SSH login and passwordless sudo):

```sh
warbler_host_key=$(ssh-keygen -F nixos.bed.einic.org |
  awk '$2 == "ssh-ed25519" { print $2 " " $3; exit }' | base64 | tr -d '\n')
test -n "$warbler_host_key"
nix build --accept-flake-config --no-link -L \
  --builders "ssh-ng://nixos@nixos.bed.einic.org?remote-program=sudo%20nix-daemon x86_64-linux /Users/cody/.ssh/id_ed25519 4 100 benchmark,big-parallel,kvm,nixos-test - $warbler_host_key" \
  --option builders-use-substitutes true \
  path:.#checks.x86_64-linux.warbler-vm
```

This does not install Warbler: the live CD's Nix store and temporary build
directory are RAM-backed, and disko runs only inside the installer VM against
its virtual disk. No persistent builder configuration is needed. The explicit
key path and pinned host key let the local Nix daemon connect without relying
on the invoking user's SSH configuration; adjust the key path on other clients.

The test installs disko onto an 8 GiB disposable virtual disk, boots through
OVMF and Lanzaboote with public test-only signing keys, and uses a persistent
software TPM. It exercises credential provisioning, SSH passphrase unlocking,
TPM enrollment, unattended reboot, Btrfs root recreation (including nested
subvolume deletion), sibling-subvolume persistence, rejection after PCR 7 changes,
and passphrase fallback with the virtual TPM token removed. No production
disk, TPM, credential, or EFI variable is touched.
It also decrypts a non-secret SOPS fixture using a public test SSH identity
before user creation, then checks decryption and key stability after root reset.

The three nodes are an installer, SSH client, and warbler. The installer shuts
down before warbler boots. The test permits QEMU software emulation (TCG), so
the builder does not need to advertise KVM or provide a login shell. KVM is
used if available. Allow up to an hour on a slow emulator; it uses approximately
4 GiB of guest RAM during the boot tests. The live-CD KVM runner is the validated
path; software emulation has not been validated end-to-end.

Hardware-specific modules are replaced with virtio devices. `/`, `/nix`, `/persist`,
and `/home` use the actual encrypted Btrfs layout; immutable Nix store objects
are shared read-only using 9p, with a writable overlay on encrypted `/nix` for
generation bookkeeping. Wi-Fi services are
disabled in the VM: its sealed Wi-Fi credential is decrypted through systemd,
while SSH traffic uses a private virtual Ethernet network. Actual radio and
firmware behavior still need a cold-boot check on warbler.

Read the build log with `nix log path:.#checks.x86_64-linux.warbler-vm`.
On a Linux machine with local QEMU access, build `checks.x86_64-linux.warbler-vm.driverInteractive` and
run its `bin/nixos-test-driver --keep-machine-state` for interactive debugging.

References: [Lanzaboote Secure Boot setup](https://nix-community.github.io/lanzaboote/getting-started/enable-secure-boot.html),
[Lanzaboote measured boot](https://nix-community.github.io/lanzaboote/how-to-guides/enable-measured-boot.html),
[systemd-creds source documentation](https://github.com/systemd/systemd/blob/v260/man/systemd-creds.xml).
