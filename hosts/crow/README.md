# Crow

Inspected over passwordless SSH at `nixos@nixos.bed.einic.org` on 2026-10-08:
x86_64 AMD, 64 GB RAM, UEFI, TPM 2.0, Secure Boot disabled. Wi-Fi is
`wlp6s0` (`mt7921e`, permanent address `44:0f:b4:22:d8:38`). Ethernet is
unplugged. The target WD_BLACK SN850X 4000GB is identified by
`/dev/disk/by-id/nvme-eui.e8238fa6bf530001001b448b4036d241`.
Its existing NTFS partition must only be erased after explicit confirmation.

## Storage and boot

`disko.nix` defines a 2 GiB ESP and a LUKS2 `cryptroot` partition containing
LVM volume group `crow`. The `root` LV initially holds 1,000,000,000,000 bytes
(1 TB, rounded up to a whole LVM extent), shared by the Btrfs `/root`, `/nix`,
`/persist`, and `/home` subvolumes. The `swap` LV holds 8 GiB. The remaining
roughly 3 TB stays unallocated in the volume group. There is no swap file,
second encryption password, zram device, or hibernation configuration.

Like Warbler, the root subvolume is recreated at boot. The reset service waits
for `/dev/mapper/crow-root`, after LUKS unlock and LVM activation. Persistent
homes, Nix store, system state, SSH identity, and container storage survive.
Never run Warbler's reset script against this machine: its filesystem is
directly on `cryptroot`, while Crow's filesystem is on the root LV.

`volume-identity.nix` records the installed volume's public identity. The normal
`crow` output enables remote and TPM support using that pin. The installed
`crow-bootstrap` output always disables TPM and remote unlock; its first boot
requires the LUKS password at the console. Secure Boot signing uses Lanzaboote; signing keys and firmware
enrollment must be provisioned before relying on it. Neither a build nor this
configuration enrolls firmware keys or a TPM disk token.

## Wi-Fi and SOPS

The existing `billy` WPA3/SAE profile was converted to an iwd profile and
SOPS-encrypted in `secrets.yaml`. Its recipients are the admin PGP key from
`.sops.yaml` and the installer SSH identity recorded in `ssh-host-key.pub`.
Decryption was verified on the installer without printing credentials.
**Preserve `/etc/ssh/ssh_host_ed25519_key` from the installer before rebooting
or replacing it**, then install it at `/persist/ssh/ssh_host_ed25519_key`
with root ownership and mode 0600. Its public key must match this directory's
`ssh-host-key.pub`. Generating another identity requires SOPS re-encryption.

Stage 2 decrypts the profile with SOPS before starting iwd, then copies it to
`/var/lib/iwd/billy.psk` and `/persist/credstore/wifi` (root-only regular files).
The latter is the input to the existing TPM credential-sealing helper. iwd
handles authentication; systemd-networkd handles DHCP and IPv6 RA, and resolved
handles DNS. A MAC-matched link file preserves `wlp6s0` in both boot stages.
NetworkManager, wpa_supplicant, and iwd's built-in IP configuration are disabled.

For edits, run `sops hosts/crow/secrets.yaml`; `wifi` contains the complete iwd
profile, including `[Security]` and `[Settings]`. Keep the passphrase for SAE;
a WPA2-derived PSK alone cannot authenticate SAE. Renaming the SSID also
requires changing both profile filenames in the configuration.

After switching to updated SOPS credentials, verify iwd reconnects before
installing another boot generation. The bootloader hook runs before normal
activation, so a second `nixos-rebuild boot` is needed to reseal the newly
activated profile into the recovery initrd. Never put decrypted credentials
in the checkout, Nix expressions, or an unencrypted initrd secret.

Recovery uses the secure-unlock module's iwd backend and a TPM-sealed copy of
the profile. It only starts when a disk passphrase is requested. SOPS on the
encrypted root is not used during early boot. Only the encrypted credential
blob enters the initrd; iwd receives its plaintext in a private runtime
directory. Read the [secure-unlock procedure](../../docs/secure-unlock.md)
for the Secure Boot/PCR 7 sealing prerequisites.

## AI container

`crow-ai` reuses Warbler's AI guest tools, user services, persistent home, and
unprivileged `cody-ai` user. Crow has no host-level `cody-ai` account or legacy
sandbox service. The container uses veth addresses `10.80.0.1` (host) and
`10.80.0.2` (guest), with NAT through Wi-Fi. It does not depend on an Ethernet
macvlan or a separate LAN DHCP lease. Container DNS uses 1.1.1.1 and 9.9.9.9.

After authenticating Crow to Tailscale, access the guest with
`ssh -p 2223 cody-ai@crow`. The SSH proxy only listens on the Tailscale
interface. The host also advertises `10.80.0.2/32`; accessing that route needs
approval in the tailnet. This configuration does not register a `crow-ai`
Tailscale node or create DNS records. From Crow itself, use
`ssh cody-ai@10.80.0.2`.

Authenticate AI providers within the new container. No existing Warbler
account, provider credentials, or working files are copied. Manage Codex with
`sys update-codex` and `sys restart-codex` as the guest user.

## Installation checkpoints

The updated bootstrap exposes `sudo sys setup-secure-boot`. After backing up
all four firmware databases with `sudo sys backup-secure-boot` and copying
that backup off-machine, use firmware settings to enter Setup Mode. Confirm
`sudo sbctl status` reports Setup Mode enabled, then run
`sudo sys setup-secure-boot` to enroll Crow's existing signing keys along with
Microsoft's certificates. Finally enable Secure Boot in firmware, boot again,
and check `sudo sbctl status`. The command does not clear firmware keys,
create replacement signing keys, enable Secure Boot in firmware, or enroll
the LUKS TPM token.

The initially installed bootstrap predates this command. On that generation,
the equivalent enrollment command is `sudo sbctl enroll-keys --microsoft`,
with the same backup and Setup Mode prerequisites. Its `backup-secure-boot`
helper incorrectly required the hostname Warbler; update the bootstrap before
using that helper. Continue using `crow-bootstrap` for this update, since the
normal Crow output requires the later sealed recovery credentials.

`sys setup-luks-tpm-unlock` belongs to the later, pinned Crow configuration;
its absence in the bootstrap is intentional.

Use the [Warbler setup procedure](../warbler/README.md#initial-provisioning-manual-steps-and-attended-firmware-checkpoints)
for the signing-key and firmware checkpoints, adapting paths and host names
below. Do not use `scripts/warbler-install.py`: it targets Warbler's disk and
provisioning identity. Crow's bootstrap supports Wi-Fi after console unlock;
Ethernet is not required. Firmware menus may differ from Warbler's HP machine.

1. Confirm the exact NVMe and that its NTFS data may be erased. Preserve the
   installer SSH key pair in a private location outside the checkout; it must
   survive the installer reboot. Prepare a separate LUKS recovery password in
   the root-owned mode-0600 installer file `/run/crow-luks-password`.
2. Build and review the disk script. Running it is the destructive operation:
   `nix build --no-link --print-out-paths path:.#nixosConfigurations.crow-bootstrap.config.system.build.diskoScript`.
   Only after approval, run that exact script on the installer. Verify `/mnt`,
   `/mnt/nix`, `/mnt/home`, `/mnt/persist`, and `/mnt/boot` mount the intended
   devices. `lvs` must show the root and swap LVs; `vgs` must show free extents.
3. Install the preserved SSH key pair into `/mnt/persist/ssh/`, directory mode
   0700, private key mode 0600. Create root and cody console passwords using
   `hosts/warbler/account-passwords.py initialize --root /mnt --password-dir
   /run/crow-account-passwords`, with root-only files named `root` and `cody`.
   The helper needs Python, mkpasswd, and util-linux. Keep passwords outside
   the checkout and remove temporary plaintext after provisioning.
4. Generate sbctl signing keys with its key directory set to
   `/mnt/persist/var/lib/sbctl/keys` and GUID file to
   `/mnt/persist/var/lib/sbctl/GUID`, as in Warbler's procedure. Copy this
   checkout into `/mnt/persist/nixos-config`, then install with
   `nixos-install --no-root-passwd --flake path:.#crow-bootstrap`.
5. Boot with local console access, unlock LUKS, and verify Wi-Fi, SOPS,
   persistent files, swap, and container connectivity. Back up existing firmware
   keys with `sudo sys backup-secure-boot`, then complete the documented manual
   Secure Boot enrollment and cold-boot verification.
6. Obtain `sudo sys root-volume-key-id` and record the quoted public value in
   `hosts/crow/volume-identity.nix`; never reuse Warbler's value or a test pin.
   This enables Crow's remote/TPM configuration. Build that system without
   activation, then run its `sw/bin/sys setup-unlock-tailscale` with sudo to
   provision the separate `crow-unlock` identity before installing boot files.
   Rebuild for boot; the hook seals the SSH/Wi-Fi/Tailscale credentials.
7. Cold-boot with console recovery available and verify
   `ssh -t -p 2222 root@crow-unlock` can unlock the disk over Wi-Fi. Retire
   unpinned bootstrap artifacts and their accepted measurements before running
   `sudo sys setup-luks-tpm-unlock`. Verify an unattended cold boot separately.

## Validation

From this checkout (the `path:` form includes newly created, untracked files):

```sh
nix eval --impure --json --file scripts/test-crow.nix
python3 scripts/test-secure-unlock-setup.py
nix build --no-link path:.#nixosConfigurations.crow.config.system.build.toplevel
nix build --no-link path:.#nixosConfigurations.crow.config.system.build.diskoScript
nix flake check --no-build path:.
```

The configuration test checks LVM/swap wiring, reset ordering, the absence of a
host AI account, container routing, SOPS ordering, and sealed iwd recovery.
Evaluation and builds do not test physical Wi-Fi reconnection, firmware
trust, disk formatting, TPM enrollment, or boot. Installation and activation
are separate steps.

Preparation results (2026-10-08): Crow system and disko script builds passed;
a recovery initrd with a synthetic evaluation-only volume pin also built.
`test-crow.nix`, Warbler's existing volume-pin checks, and all 31 secure-unlock
Python tests passed. Full flake evaluation stops at the existing Warbler VM
fixture's missing `services.zpl-proxy-api` option; the same failure was
reproduced from unchanged HEAD. No target disk was formatted and no system
was installed, activated, or rebooted during these checks.

## Installation result

Crow bootstrap was installed on 2026-10-08 after approval to erase the NVMe.
PhotoRec was stopped with separate approval after it blocked formatting.
The root LV is 1,000,001,765,376 bytes (extent-rounded), swap is 8,589,934,592
bytes, and 2,990,027,046,912 bytes remain free in volume group `crow`.
The installed system is
`/nix/store/1c7s7mxd4bgck100a779ll9wbvb25xyd-nixos-system-crow-26.11.20261003.a7868a7`.
The volume identity is recorded in both this checkout and the installed copy
at `/persist/nixos-config`. The EFI bootloaders and generation UKI passed
certificate verification, and the kernel/initrd matched the hashes embedded
in the signed UKI. The LUKS recovery password passed a test unlock. The
installed SSH key decrypted the Wi-Fi SOPS file,
and both initial account passwords were verified against the installed hashes.

The private provisioning bundle on the installing machine is
`/home/cody-ai/.local/share/crow-install` (directory mode 0700, files 0600):

- `account-passwords/root`: initial root console password.
- `account-passwords/cody`: initial cody console password.
- `luks-password`: separate disk recovery password.
- `ssh/`: preserved stage-2 SSH/SOPS identity.
- `sbctl/`: signing keys and owner GUID.

These plaintext files are outside Git and the Nix store. Crow stores only the
account hashes in `/persist/shadow.d/{root,cody}`. Later `passwd` changes persist
those hashes but do not update the saved initial plaintext passwords. SSH stays
key-only. Temporary provisioning passwords on the live installer were removed
after validation; the local private bundle is retained.

The installer has not been rebooted. First-boot Wi-Fi, container connectivity,
and persistence remain to be verified after local LUKS entry. Secure Boot key
enrollment, `crow-unlock` Tailscale registration, and TPM auto-unlock are still
pending the attended firmware and recovery checkpoints above. Do not install
the normal `crow` boot generation until those prerequisites are ready.

## First-boot fixes (2026-10-09)

The updated bootstrap was switched live on Crow and installed for its next
boot. It provides `sys setup-secure-boot`, corrects the backup helper's host
check, and explicitly configures both sides of the AI container's veth with
networkd. Previously systemd's default container network replaced the host
address and the guest waited indefinitely for a managed link, causing repeated
container startup failures. Crow and its guest now report no failed units;
`crow-ai` reaches network-online, can fetch over HTTPS, and runs the installed
Codex daemon with zero container restarts since the update.

The secure-unlock helper now accepts LVM inside the configured LUKS mapping.
Every backing-device branch must reach that mapping; an LV spanning an
unencrypted device is rejected. Tests cover direct, nested, mixed-device,
missing-device and cyclic cases, and Crow's actual LV ancestry was checked.
All 36 helper tests and Crow's configuration checks passed.

Firmware databases were backed up successfully to
`/persist/secure-boot-backup/2026-10-09T21-30-37Z-gLL2ua0F` and copied to the
installing machine at
`/home/cody-ai/.local/share/crow-install/firmware/2026-10-09T21-30-37Z-gLL2ua0F`.
PK, KEK, db and dbx checksums match. Bootloader and generation UKI signatures
were verified against Crow's signing certificate.

Remaining manual steps: enter firmware Setup Mode, boot Crow and run
`sudo sys setup-secure-boot`, then enable Secure Boot in firmware and cold-boot
again. Normal-host Tailscale is still logged out; authenticate it with
`sudo tailscale up` to use the tailnet SSH proxy and advertised routes.
After Secure Boot is verified, complete the separate `crow-unlock` registration,
sealed recovery credential installation and remote-unlock test described above.
Only then retire accepted unpinned bootstrap generations and enroll the disk's
TPM token. No firmware keys or LUKS tokens were changed by this live update.
