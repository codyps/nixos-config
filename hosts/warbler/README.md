# Warbler

The reusable module and setup commands are documented in [Secure unlock](../../docs/secure-unlock.md).

Inspected at `nixos@nixos.bed.einic.org`: x86_64 AMD, 64 GB RAM, UEFI,
TPM 2.0 (`systemd-pcrlock is-supported` returned `yes`), Secure Boot disabled.
The installer currently uses Wi-Fi `wlp3s0` (rtw89_8852ae); `eno1` is unplugged.

## Remote rebuild

From the local checkout root, run:

```sh
nix run .#warbler-nixos-rebuild-remote
```

This archives the checkout and its flake inputs into Warbler's Nix store over
SSH as `cody@warbler`, then runs `sudo nixos-rebuild boot` there using the
archived source. It installs the next boot generation without rebooting.
Tracked uncommitted edits are included; add new files to Git first.
To select another rebuild action, use e.g.
`nix run .#warbler-nixos-rebuild-remote -- switch` or `-- build`.

## AI harness account

See [AI harness account](ai-harnesses.md) for the restricted `cody-ai` user,
boot-started Codex service, phone pairing, and desktop SSH connection.

The [alternate AI container](ai-container.md) provides a separate NixOS
environment for Codex, Hermes, and other harnesses, with its own LAN DHCP address
and user systemd. The existing host AI setup remains available independently.

## Hardware and firmware references

User-supplied `lshw` identifies an **HP EliteDesk 805 G8 Desktop Mini PC**,
SKU `63C34UC#ABA`, motherboard `8881`, BIOS **T26 02.14.00**, dated
2024-11-21.

HP's [805 G8 Mini Maintenance and Service Guide](https://kaas.hpcloud.hp.com/pdf-public/pdf_10300705_en-US-1.pdf)
is listed on the [EliteDesk 805 G8 Desktop Mini support page](https://support.hp.com/us-en/product/setup-user-guides/hp-elitedesk-805-g8-desktop-mini-pc/2100378016)
under the title **HP Elite Mini 805 G8 Desktop PC**. Printed pages 67–68
(PDF pages 74–75) describe Sure Start and Secure Boot key management;
printed page 105 (PDF page 112) describes clearing custom keys. The
[commercial BIOS guide, June 2023](https://ftp.hp.com/pub/caps-softpaq/cmit/whitepapers/HPBIOSSetup.pdf)
also lists the 805 G8 DM but covers a superset of firmware settings.

The G8 manual documents key clearing but does not explicitly call the result
Setup Mode or guarantee that `dbx` survives. HP's older
[Secure Boot Customization Guide](https://h10032.www1.hp.com/ctg/Manual/c05649759.pdf#page=8)
documents database backup and the disable/save/re-enter/clear sequence. Physical
T26 behavior and database restoration remain unverified. The complete action
sequence is in the initial provisioning instructions below.

## Setup

 - EFI part, and Luks2 partition. btrfs on luks2.
 - luks2 partition pined with `fixate-volume-key` in initrd


The normal configuration pins `cryptroot` with systemd's `fixate-volume-key=`
in the signed initrd. This applies to both passphrase and TPM unlock, before
the Btrfs root-reset service can mount anything. `boot.secureUnlock.rootVolumeKeyId` is
the public HMAC-SHA256 identity of the installed volume, derived from its
volume key and the string `cryptsetup:cryptroot:<LUKS UUID>`; it is not a key
or the digest stored in the LUKS header. Changing the volume key, UUID, or
mapper name requires a new pin. Changing the recovery password does not.

`warbler-bootstrap` explicitly sets this identity to null and disables remote
and TPM disk unlock. Use it only for attended installation of a new volume.
The remote installer records the freshly formatted volume's identity in
`hosts/warbler/volume-identity.nix` in the installed checkout. For a manual
installation, obtain the identity on the trusted installed system and update
that file before building the normal configuration. `configuration.nix` imports
it as `boot.secureUnlock.rootVolumeKeyId`; the repository retains the current installation's
known identity. Never automatically
learn the expected identity from a disk during boot. An unpinned configuration
cannot enable remote or TPM unlock. Pinning authenticates volume identity,
not every filesystem block or its freshness.

On the trusted installed system (including `warbler-bootstrap`), run:

```sh
sudo root-volume-key-id
```

Or run directly from this checkout on Linux, without installing the command:

```sh
sudo nix run .#luks-volume-key-id -- --device /dev/disk/by-partlabel/disk-system-crypt --name cryptroot
# Automation with an existing passphrase file:
sudo nix run .#luks-volume-key-id -- --device /dev/disk/by-partlabel/disk-system-crypt --name cryptroot --key-file /run/warbler-luks-password
```

The package includes Python and libcryptsetup; no system Python or cryptsetup
installation is needed. This command operates on Linux LUKS devices.

For other devices, use the [general LUKS identity command](../../docs/luks-volume-key-id.md)
with an explicit encrypted device and target mapper name:

```sh
sudo nix run .#luks-volume-key-id -- --device /dev/sdb2 --name data
```

Enter the LUKS recovery passphrase. The command prints just the 64-character
public ID to stdout; save it as a quoted Nix string in
`hosts/warbler/volume-identity.nix`. It reads the configured LUKS device and
derives the ID for mapper name `cryptroot`, without opening a mapping,
changing the header, or writing the raw volume key to a file. The derivation
matches [systemd's volume-key identity](https://github.com/systemd/systemd/blob/main/src/shared/cryptsetup-util.c).
For provisioning automation with an existing passphrase file in RAM:

```sh
sudo root-volume-key-id --key-file /run/warbler-luks-password
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
The wired interface uses the same explicit DHCP DUID and IAID in both boot
stages, preserving its normal-system DHCP identity before `/persist` is unlocked.
When deploying this change, let old early-boot leases expire or remove only
those stale leases from the router, then verify DNS after a full boot.
Stage 2 SSH uses port 22 and a separate persistent host key. Both root and cody
accept authorized SSH keys; cody has passwordless sudo. Root and cody have
installer-generated console passwords. SSH password authentication stays disabled.
The LUKS passphrase is separate from both account passwords.

The installer retains the initial plaintext passwords only in its private local
bundle, `~/.local/share/warbler-install/account-passwords/{root,cody}`. Warbler
stores yescrypt hashes in root-owned mode-0600 `/persist/shadow.d/{root,cody}`
(directory mode 0700). This is a host-specific hash directory consumed through
NixOS `hashedPasswordFile`, not a replacement for the standard `/etc/shadow`.
No passwords or hashes are evaluated by Nix or embedded in the Nix store.

**Change your password with `passwd`**; administrators can use `sudo passwd cody`
or `sudo passwd root`. The PAM hook saves the resulting hash before reporting
success. Rebuilds and ephemeral-root resets reuse that hash while
`users.mutableUsers = false` continues to enforce account definitions. PAM-based
`chpasswd` is supported too when invoked from the shadow package. Administrative
lock/delete flags, direct `/etc/shadow` edits, `chpasswd -e`, and `usermod -p`
bypass the hook and are not persistent password-change interfaces.
The installing machine's saved initial password becomes stale after a user
changes it; later installs/retries do not overwrite an existing hash.

Store the authoritative plaintext inputs in root-owned mode-0600 files
`/persist/credstore/ssh-host-key` and, when Wi-Fi is enabled,
`/persist/credstore/wifi`. Keep the directory mode 0700. `/persist` is inside
LUKS-encrypted cryptroot; these inputs never enter the Nix store or initrd.
The boot service and bootloader-install hook seal them into
`/persist/credstore.encrypted`, reusing unchanged decryptable blobs and
resealing changed inputs or blobs that no longer decrypt.

Initrd Ethernet, SSH, and optional Wi-Fi start only when systemd requests a
disk passphrase. Successful TPM auto-unlock leaves these services idle until
normal boot. Recovery therefore includes the time needed to establish the
network connection. The local console passphrase prompt remains available.

Early Wi-Fi and SSH **always require TPM-encrypted credentials**, even when
`boot.secureUnlock.tpmUnlock.enable = false`. Only these ciphertext files
are appended to the initrd at installation/rebuild time:

| Source on encrypted storage | Credential name | Consumer |
| --- | --- | --- |
| `/persist/credstore.encrypted/wifi` (optional) | `wifi` | wpa_supplicant in both boot stages |
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
```

Back up the generated bundle to separately encrypted offline storage, then run:

```sh
python3 scripts/warbler-install.py install
```

`install` includes the preflight checks and bootstrap build. Separate `check`
and `build` runs are optional rehearsals, not required installation steps.

- `prepare` captures `apple-password-gen` output without displaying it and
  generates RSA-4096 PK, KEK, and db keys/certificates with local OpenSSL. It
  checks key/certificate matches and uses sbctl-compatible PKCS#8 keys. Repeat
  runs validate and retain the existing bundle, never silently rotate it.
  It also generates distinct root and cody account passwords under
  `account-passwords/`, and a separate Ed25519 stage-2 SSH/SOPS identity under `ssh/`.
  Older bundles gain missing account passwords and SSH identity on `prepare`
  without rotating existing credentials. Partial bundles are rejected, not replaced.
- Local storage defaults to `~/.local/share/warbler-install`: `luks-password`
  contains the exact password bytes, and `sbctl/` contains `GUID` and
  `keys/{PK,KEK,db}/`. Directories are private and files are mode 0600. A
  defensive `.gitignore` ignores everything in the bundle. **The bundle must
  remain outside this checkout.** The tool rejects in-checkout secret paths. `--secrets-dir /absolute/external/path` overrides the location.
- These local files are plaintext, not a password-manager entry or SOPS
  archive. Protect the Mac's disk with encryption and make a separately
  encrypted offline backup before installing. Retrieve the password privately
  from the local file when the console/SSH LUKS prompt needs it; do not paste it
  into commands, logs, Git, or this conversation.
- `check` validates the bundle and performs read-only host/disk checks. It
  requires existing trusted SSH host keys, key authentication, and passwordless
  sudo. It displays model/capacity, not hardware serial numbers.
- `install` first generates missing account passwords in the local bundle,
  retaining any existing ones. It sends a source-only snapshot (tracked plus nonignored untracked
  files), builds `warbler-bootstrap` and disko **without any secrets**, and
  rechecks the expected empty NVMe. It then requires the exact typed erase
  confirmation. Only afterward are secrets sent over SSH to a separate,
  root-only live-RAM directory, outside the flake source. Disko reads the
  password at runtime; the keys are copied into encrypted `/persist` before
  bootloader signing. The local password is not a Nix argument or store input.
  The stage-2 SSH host key is installed at `/persist/ssh/ssh_host_ed25519_key`
  before `nixos-install`, so early SOPS secrets can decrypt on first activation.
  The installer hashes the account passwords into `/mnt/persist/shadow.d` before
  account activation. Plaintext account inputs remain in live RAM until cleanup;
  the installer retains its private local copy.
  After formatting, it derives the new root-volume identity using the recovery
  passphrase file and records it in the installed checkout's
  `hosts/warbler/volume-identity.nix`. It does not print the identity or modify
  the source checkout on the Mac. Preserve that installed file when updating
  the checkout; copying another installation's pin will prevent unlocking.
  Before a later deployment from the Mac, copy the installed public identity
  file back into its checkout.
  `check`, `build`, and `install` require it to match `ssh-host-key.pub` here.
- `build` runs that same source-transfer/build/preflight path but stops before
  confirmation, secret transfer, or disk changes. Use it to validate the remote
  build path safely before the installation window.
- The installer persists the checkout at `/persist/nixos-config`,
  cleans up remote temporary secrets on normal exit,
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
After Secure Boot verification, one rebuild to `.#warbler` seals credentials,
installs remote unlock, and prepares measured boot for optional TPM enrollment.
The bootloader hook creates the credentials before including them in the initrd.

This automates installation preparation, transfer, formatting, and signing—not
the attended T26 firmware-key operation and Setup Mode verification. Have someone at the local console
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

1. **Configure BIOS before installation:** have backups, the BIOS administrator
   password, keyboard/display, an installer USB, and the SSH private key
   corresponding to an authorized key in `nixos/ssh-auth.nix`. Plug in Ethernet
   (bootstrap has no installed Wi-Fi service). If firmware updates are planned,
   finish them first; this runbook does not prescribe a BIOS update. Press
   **F10**, authenticate, and apply all these settings in this visit:

   | Location | Setting / action |
   | --- | --- |
   | Security → TPM | Set **TPM Device to Available** and **TPM State to Enabled**. Leave **Clear TPM** unselected. |
   | Security → BIOS Sure Start | **Disable Sure Start Secure Boot Keys Protection** (required to change Secure Boot keys). Leave other Sure Start protections unchanged. |
   | Security → Secure Boot Configuration | **Disable Secure Boot** (allows the unsigned installer and bootstrap to boot). |
   | Security → Secure Boot Configuration → Secure Boot Key Management | Leave **Clear Secure Boot keys**, **Import Custom Secure Boot Keys**, and **Reset Secure Boot keys to factory defaults** unselected (back up the existing keys before clearing them). |
   | Wi-Fi device setting, if using optional initrd Wi-Fi | **Enable Wi-Fi** (the Linux initrd needs the device). |

   **Save changes and boot the installer USB in UEFI mode.** Keep these settings
   through installation. The later BIOS visits only clear keys after backup
   and enable Secure Boot after enrollment.

2. **Live USB: prepare the checkout:** obtain this flake checkout on the live host. Enter a root shell (`sudo -i`) and
   `cd` to that checkout. All installer commands below run there as root.
   Use `.#warbler-bootstrap` for installation; leave the normal configuration
   unchanged. This output disables remote and TPM disk unlock and omits encrypted
   initrd credentials and Wi-Fi services until credentials can be sealed against
   the final Secure Boot state. Disk unlocking is local-console only during
   bootstrap; administration after boot is via wired SSH.

3. **Live USB — inspect, then format the NVMe:** inspect without displaying
   serial numbers:

   ```sh
   test -d /sys/firmware/efi
   lsblk -o NAME,PATH,SIZE,MODEL,TYPE,FSTYPE,MOUNTPOINTS
   nix build --accept-flake-config --no-link --print-out-paths \
     .#nixosConfigurations.warbler-bootstrap.config.system.build.diskoScript
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

   **Provision initial account passwords:** on the installing machine, run
   `python3 scripts/warbler-install.py prepare` to generate or retain its private
   bundle. Copy that bundle's `account-passwords/` directory to
   `/run/warbler-account-passwords` on the installer with root ownership,
   directory mode 0700, and file mode 0600. Then run on the installer:

   ```sh
   nix shell --inputs-from . nixpkgs#python3 nixpkgs#mkpasswd nixpkgs#util-linux --command \
     python3 hosts/warbler/account-passwords.py initialize \
       --root /mnt --password-dir /run/warbler-account-passwords
   rm -r /run/warbler-account-passwords
   ```

   This creates only missing `/mnt/persist/shadow.d/{root,cody}` hashes and
   never resets a current password. The remote installer does this automatically.
   Keep the original local bundle to retrieve the initial console passwords.

   ```sh
   mkdir -p /mnt/persist/var/lib/sbctl
   nix shell --inputs-from . nixpkgs#sbctl --command \
     sbctl --config /run/warbler-sbctl-install.conf create-keys
   mkdir -p /mnt/persist/nixos-config
   cp -a . /mnt/persist/nixos-config/
   nixos-install --no-root-passwd --flake .#warbler-bootstrap
   ```

   Stop on any failure. Lanzaboote needs these keys before installation signs
   the boot files. The checkout is copied to persistent storage because `/`
   is blanked on boot; keep secret files outside it. Back up signing keys to
   separately encrypted offline storage. Remove the temporary passphrase file
   after successful installation (`rm /tmp/warbler-luks-password`).

5. **First installed boot: verify signatures and back up firmware keys.**
   Keep Secure Boot disabled, boot the NVMe, and unlock LUKS at the console.
   Connect over wired SSH as `root@<wired-ip>` and run:

   ```sh
   cd /persist/nixos-config
   sbctl verify
   warbler-secure-boot-backup
   ```

   Inspect signature reports for the active bootloader and UKI; standalone
   initramfs files are not individually signed. The backup command saves PK,
   KEK, db, and dbx under `/persist/secure-boot-backup/`, with readable listings,
   boot status, and checksums. Require its `COMPLETE` marker, which is written
   only after all four nonempty exports pass checksum verification. Copy the
   backup to separate storage before clearing keys.

   If importing an existing initrd SSH identity, install its private key at
   `/persist/credstore/ssh-host-key` now, with root ownership, directory mode
   0700, and file mode 0600. Otherwise skip this: the first Secure Boot boot
   generates and retains a dedicated identity automatically.

6. **Enter Setup Mode.** Restart, press **F10** (or **ESC**, then Setup), and
   authenticate. Under **Security → Secure Boot Configuration → Secure Boot
   Key Management**, select **Clear Secure Boot keys**. Leave **Import Custom
   Secure Boot Keys** and **Reset Secure Boot keys to factory defaults**
   unselected. Save changes and accept the firmware confirmation.
   Boot the installed NVMe, unlock LUKS locally, reconnect over wired SSH,
   and run `sudo sbctl status`. Require **Setup Mode: Enabled** before continuing.
   If it is not enabled, revisit BIOS; do not attempt enrollment yet.

7. **Enroll signing keys and enable Secure Boot.** On the installed system, run:

   ```sh
   sudo sbctl enroll-keys --microsoft
   ```

   Restart into **F10 → Security → Secure Boot Configuration** and enable
   **Secure Boot**. Save changes, shut down, and power on again.

8. **Verify the Secure Boot cold boot.** Boot the NVMe, unlock LUKS locally,
   reconnect over wired SSH, and run:

   ```sh
   sudo bootctl status
   sudo sbctl status
   sudo sbctl verify
   ```

   Require Secure Boot enabled in user mode, Setup Mode disabled, and valid
   signatures on the active bootloader and UKI. Stop if firmware restored or
   rejected the custom keys. Finish any further BIOS changes and repeat this
   verification before sealing credentials.

9. **Prepare remote unlock and optional disk enrollment in one rebuild.**
   Work from `/persist/nixos-config`. The remote installer has already recorded
   the new volume identity in `hosts/warbler/volume-identity.nix`. For a manual
   install, run `sudo root-volume-key-id` and save the returned ID as a
   quoted Nix string in that file. Never reuse the previous installation's pin.

   Keep these normal configuration settings enabled:

   ```nix
   boot.secureUnlock.remoteUnlock.enable = true;
   boot.secureUnlock.tpmUnlock.enable = true;
   ```

   The second setting prepares measured boot and TPM unlocking support; it
   **does not enroll the disk**. A freshly installed disk still asks for its
   LUKS passphrase until you explicitly enroll it. This lets the same cold boot
   verify remote recovery and prepare for optional enrollment, without another
   configuration change, rebuild, and preparatory reboot later.

   Ethernet needs no credential preparation: the hook creates and retains the
   dedicated initrd SSH identity automatically. For optional Wi-Fi, set
   `boot.secureUnlock.remoteUnlock.wifi.enable = true` and install the complete
   wpa_supplicant configuration before rebuilding:

   ```sh
   sudo install -d -m 0700 /persist/credstore
   sudo install -o root -g root -m 0600 /run/warbler-wifi.conf /persist/credstore/wifi
   ```

   Rebuild and record the initrd SSH fingerprint:

   ```sh
   sudo nixos-rebuild boot --flake .#warbler
   sudo ssh-keygen -lf /persist/credstore.encrypted/ssh-host-key.pub
   ```

   The bootloader hook generates or reuses the SSH identity, seals the SSH and
   optional Wi-Fi credentials, verifies decryption, and includes the ciphertext
   in the initrd before signing. No separate service-start command is needed.
   Missing Wi-Fi input, bad permissions, or failed sealing stops installation
   of the boot files. Rebuild after later credential changes too; starting the
   provisioning service alone does not update an already-built initrd.
   Back up `/persist/credstore` to separately encrypted offline storage.

   On success, power off and start again with console access available.
   Keep Ethernet connected unless explicitly testing Wi-Fi. From the workstation,
   run `ssh -t -p 2222 root@<warbler-ip>`, verify the recorded fingerprint, and
   enter the LUKS passphrase. Verify normal SSH on port 22 and persistence.
   This completes installation with remote unlock. If it fails, unlock locally
   and reconnect Ethernet for diagnosis; do not clear the TPM or reformat.
   Keep the preceding bootstrap generation available during provisioning only.

## Tailscale recovery identity

Warbler enables `boot.secureUnlock.remoteUnlock.tailscale.enable` for a separate
`warbler-unlock` node in the initrd. Follow the
[Tailscale provisioning procedure](../../docs/secure-unlock.md#separate-tailscale-identity-in-the-initrd)
before installing this configuration's boot files. Run the new system closure's
`secure-unlock-setup enroll-tailscale`, authenticate the separate node and disable
its key expiry, then install the boot generation. Its state is sealed to TPM
PCR 7; the normal host's `warbler` identity and state remain separate.

When a disk passphrase is requested, connect with
`ssh -t -p 2222 root@warbler-unlock`. Automatic TPM disk unlock skips recovery
networking. Test this path with console access before relying on it.

## Optional automatic disk unlock

After step 9 succeeds, the installed generation is already prepared for TPM
unlocking. You can stop with remote passphrase unlock, or enroll later without
another configuration change. There is no additional BIOS toggle for LUKS
unlocking. If you have since switched generations without rebooting, boot the
current generation first; the helper requires the booted and current systems
to match.

Before enrollment, retire unpinned bootstrap boot artifacts and exclude their
measurements from the effective TPM policy. Only pinned generations should
remain accepted: an accepted unpinned generation bypasses the volume identity
check. This policy cleanup is a separate prerequisite; `enroll-disk` does not
perform it. Secure Boot must enforce the trusted boot artifacts.

Then run on Warbler:

```sh
sudo secure-unlock-setup enroll-disk
```

The helper prompts for the existing recovery passphrase, verifies it against
a token-free LUKS slot, adds a TPM token, and checks that existing slots remain
unchanged. It does not delete recovery slots. Rerunning leaves an existing
pcrlock token alone; a different TPM policy requires explicit migration.

On success, power off and start again without supplying a passphrase. Verify
normal SSH on port 22 and persistent files. Keep local console access and the
recovery passphrase until this unattended cold boot succeeds. TPM unlock
failure falls back to the LUKS passphrase; remote fallback also requires the
separately sealed SSH/Wi-Fi credentials to remain decryptable. Do not clear the
TPM or remove the passphrase slot as a test.

Lanzaboote maintains the managed PCR 0, 4, and 7 policy on subsequent bootloader
updates; eight boot generations are retained. If using an older installation
with `boot.secureUnlock.tpmUnlock.enable = false`, enable it, rebuild, and boot that
configuration before enrollment. The helper never rebuilds, changes firmware,
or reboots the machine itself.

## Validation

Run these checks from the flake checkout:

```sh
nix eval --raw .#nixosConfigurations.warbler.config.system.build.toplevel.drvPath
nix build .#nixosConfigurations.warbler.config.system.build.toplevel --no-link
nix build .#nixosConfigurations.warbler.config.system.build.diskoScript --no-link
python3 scripts/test-secure-unlock-setup.py
python3 scripts/test-warbler-install.py
python3 scripts/test-warbler-account-passwords.py
nix build .#checks.x86_64-linux.warbler-account-passwords --no-link
nix eval --impure --json --file scripts/test-warbler-volume-key.nix
nix build .#checks.x86_64-linux.luks-volume-key-id --no-link
```

Building does not format disks, install/sign the ESP, enroll credentials, or
activate the configuration. A Linux builder is required on macOS.
The account-password VM test exercises ordinary `passwd`, administrative
`chpasswd`, repeat initialization, immutable-user activation, shadow recreation,
and password login after reboot using synthetic credentials.
The Python tests mock TPM, password hashing, and disk commands; they validate failure handling,
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
  .#checks.x86_64-linux.warbler-vm
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
  .#checks.x86_64-linux.warbler-vm
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
are shared read-only using virtiofs, with a writable overlay on encrypted `/nix` for
generation bookkeeping. Wi-Fi services are
disabled in the VM: its sealed Wi-Fi credential is decrypted through systemd,
while SSH traffic uses a private virtual Ethernet network. Actual radio and
firmware behavior still need a cold-boot check on warbler.

Read the build log with `nix log .#checks.x86_64-linux.warbler-vm`.
On a Linux machine with local QEMU access, build `checks.x86_64-linux.warbler-vm.driverInteractive` and
run its `bin/nixos-test-driver --keep-machine-state` for interactive debugging.

References: [Lanzaboote Secure Boot setup](https://nix-community.github.io/lanzaboote/getting-started/enable-secure-boot.html),
[Lanzaboote measured boot](https://nix-community.github.io/lanzaboote/how-to-guides/enable-measured-boot.html),
[systemd-creds source documentation](https://github.com/systemd/systemd/blob/v260/man/systemd-creds.xml).
