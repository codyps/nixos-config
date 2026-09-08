# Robin installation

Robin is a BIOS-booted x86_64 KVM guest. Its disk is identified by
`/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0-0-0-0`.

Storage: GPT → 1 MiB BIOS embedding partition + 2 GiB unencrypted `/boot`
+ LUKS2 → `robin-vg` LVM → 4 GiB swap + remaining space for the `robin`
ZFS pool. ZFS imports from `/dev/robin-vg`, after its logical volume appears.
Root rolls back to `robin/root@blank`; `/nix`, `/home`, `/persist`, and
Syncthing data remain persistent. This layout requires formatting the disk.

## Secrets and first boot

`secrets.yaml` contains the DNS token copied from Ward and independent root
and cody password hashes. Its recipients are the admin GPG key and Robin's
pre-generated Ed25519 host key, converted to age. Password hashes use
`sops.secrets.<name>.neededForUsers`; `/persist` mounts in the initrd before
SOPS needs the key. Caddy receives its token through a SOPS environment
template and restarts when that template changes.

`../../secrets/robin-bootstrap.yaml` is encrypted **only for the admin GPG
key**. It backs up the normal SSH identity, a separate initrd SSH identity,
and the generated admin passwords and LUKS passphrase. Never add Robin as a recipient to that
file: it is the recovery source for Robin's own decryption key.

To view a generated password locally (do not paste it into chat):

```sh
nix develop --command sops decrypt --extract '["cody-password"]' secrets/robin-bootstrap.yaml
nix develop --command sops decrypt --extract '["root-password"]' secrets/robin-bootstrap.yaml
```

Before installation, restore the keys into a NEW directory outside the
repository, using a secure temporary or encrypted filesystem:

```sh
nix develop --command python3 hosts/robin/stage-bootstrap.py /private/tmp/robin-install
```

Supply `/private/tmp/robin-install/extra-files` to nixos-anywhere's
`--extra-files`. This installs both private keys in `/persist/ssh` before
activation. Preserve permissions (private keys 0600, directory 0700).
The normal key is also used by OpenSSH after boot. The initrd key is copied
into the initrd on unencrypted `/boot`; **never use it for SOPS decryption**.
The public keys alongside this README allow fingerprints to be checked.

The generated LUKS passphrase is separate from the admin credentials and is
stored as `luks-password` in the admin-encrypted bootstrap file. Extract it
into a 0600 file outside the repository (with `umask 077`), and provide it with `--disk-encryption-keys /tmp/robin-luks-password <local-file>`.
Disko uses this only for formatting/unlocking during installation; no key
file is configured for subsequent boots. Remove plaintext installation
staging and the local passphrase file after installation.

## Unlock after a reboot

```sh
ssh -t -p 2222 root@robin.einic.org
```

Authenticate with an authorized SSH key, then enter the LUKS passphrase in
the systemd password prompt. Verify the initrd identity against
`initrd_ssh_host_ed25519_key.pub`. Normal SSH resumes on port 22 as `cody`
after unlock; root SSH login is disabled. Allow TCP 2222 through any provider
firewall. Initrd uses DHCP on `en*` and explicitly loads `virtio_net`.

## Build and installation constraints

Build the system and disko closures using an available x86_64 Linux builder.
The macOS controller cannot natively build them. Pass prebuilt store paths
or explicitly select local/controller builds with configured remote builders;
do not let nixos-anywhere's automatic selection fall back to Robin.

The inspected ISO has NixOS 24.05, kernel 6.6.56 and ZFS 2.2.6. Refresh the
installer environment before running modern ZFS/disko tooling. Detection of
an existing NixOS ISO normally skips nixos-anywhere's kexec step. A reboot
into an updated ISO or a deliberately selected kexec workflow is required.

After formatting, transfer closures into the mounted target store, stage
identities, install, and export the pool cleanly before reboot. Detach the ISO
or set the provider VM to boot from disk first; otherwise it returns to the
old ISO and loses the installer session's temporary SSH authorization. Do not copy
the full closure into the ISO's small RAM-backed store. Validate a real boot,
SSH unlock, SOPS user setup, root rollback on a second boot, encrypted swap,
and Caddy before calling the installation complete.

The `virtualisation.vmVariantWithDisko` variant alone has the `nixosvmtest`
account/password. It disables production SOPS/Caddy and initrd SSH, and uses
Disko's interactive/test password instead of the installation password file.
Caddy's former missing Libation mount dependency has been removed; its
Libation data and disabled Audiobookshelf backend still need provisioning
before those routes can serve content.
