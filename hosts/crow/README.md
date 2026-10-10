# Crow

Build and installation commands below require a [prepared hardware inventory
checkout](../../docs/hardware-identities.md). The remote rebuild helper prepares
it automatically; direct Nix commands must run inside that prepared checkout.

Crow is an x86_64 AMD machine with 64 GB RAM, UEFI, and TPM 2.0.
Wi-Fi is `wlp6s0` (`mt7921e`). The installation disk is a WD_BLACK SN850X
4000GB; its exact device selector is configured in `disko.nix`.

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

`volume-identity.nix` reads the installed volume identity from the prepared inventory. Use `.#crow`
throughout: staged provisioning defers credentials and TPM policy until the
pinned host boots with Secure Boot enabled. The first unlock is at the console.
Signing keys must exist before boot-file installation. Neither the configuration
nor a rebuild enrolls firmware keys or a TPM disk token. See the
[shared staged workflow](../../docs/secure-unlock.md#staged-provisioning-with-one-configuration).

## Wi-Fi and SOPS

The `billy` WPA3/SAE iwd profile is SOPS-encrypted in `secrets.yaml`. Its
recipients are the admin PGP key from `.sops.yaml` and the installer SSH identity recorded in `ssh-host-key.pub`.
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

The Crow configuration exposes `sudo sys setup-secure-boot`. After backing up
all four firmware databases with `sudo sys backup-secure-boot` and copying
that backup off-machine, use firmware settings to enter Setup Mode. Confirm
`sudo sbctl status` reports Setup Mode enabled, then run
`sudo sys setup-secure-boot` to enroll Crow's existing signing keys along with
Microsoft's certificates. Finally enable Secure Boot in firmware, boot again,
and check `sudo sbctl status`. The command does not clear firmware keys,
create replacement signing keys, enable Secure Boot in firmware, or enroll
the LUKS TPM token.

Older installed generations may lack these helpers; rebuild `.#crow` to update
them. The same configuration works before Secure Boot enrollment. The command
`sys setup-luks-tpm-unlock` is present but refuses enrollment until its
Secure Boot, pin, current-generation and policy prerequisites are satisfied.

Use the [Warbler setup procedure](../warbler/README.md#initial-provisioning-manual-steps-and-attended-firmware-checkpoints)
for the signing-key and firmware checkpoints, adapting paths and host names
below. Do not use `scripts/warbler-install.py`: it targets Warbler's disk and
provisioning identity. Crow supports Wi-Fi after console unlock;
Ethernet is not required. Firmware menus may differ from Warbler's HP machine.

1. Confirm the exact NVMe and obtain approval to erase its existing data. Preserve
   the installer SSH key pair in a private location outside the checkout; it must
   survive the installer reboot. Prepare a separate LUKS recovery password in
   the root-owned mode-0600 installer file `/run/crow-luks-password`.
2. For a fresh format, set `crow.rootVolumeKeyId` to `null` in the
   prepared checkout's `hardware-identities.json` so it cannot reuse the previous disk identity.
   Build and review the disk script. Running it is the destructive operation:
   `nix build --no-link --print-out-paths path:.#nixosConfigurations.crow.config.system.build.diskoScript`.
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
   `nixos-install --no-root-passwd --flake path:.#crow`.
5. Boot with local console access, unlock LUKS, and verify Wi-Fi, SOPS,
   persistent files, swap, and container connectivity. Back up existing firmware
   keys with `sudo sys backup-secure-boot`, then complete the documented manual
   Secure Boot enrollment and cold-boot verification.
6. Obtain `sudo sys root-volume-key-id` and record the value in
   `crow.rootVolumeKeyId` in both the prepared inventory and the SOPS-encrypted source; never reuse Warbler's value or a test pin.
   Rebuild `.#crow`; the hook automatically generates the initrd SSH host key
   and seals available credentials. No manual SSH key generation is needed.
   Run `sudo sys setup-unlock-tailscale` to provision the separate `crow-unlock`
   identity, then rebuild for boot to include it. Wi-Fi requires the profile
   at `/persist/credstore/wifi`; initial absence defers Wi-Fi, not wired recovery.
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

## Recovery material

The private provisioning bundle on the installing machine is
`/home/cody-ai/.local/share/crow-install` (directory mode 0700, files 0600):

- `account-passwords/{root,cody}`: initial console passwords.
- `luks-password`: disk recovery password.
- `ssh/`: stage-2 SSH/SOPS identity.
- `sbctl/`: signing keys and owner GUID.
- `firmware/2026-10-09T21-30-37Z-gLL2ua0F`: firmware database backup, also
  stored on Crow at `/persist/secure-boot-backup/2026-10-09T21-30-37Z-gLL2ua0F`.

Keep these plaintext files outside Git and the Nix store. Crow stores account
hashes in `/persist/shadow.d/{root,cody}`. Later `passwd` changes persist those
hashes but do not update the saved initial passwords. SSH is key-only.
