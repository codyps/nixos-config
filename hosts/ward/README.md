# Ward recovery and secure unlock

Ward uses LUKS2 (`b8de49f4-4952-4a22-8d8c-f616b77e982e`, mapper
`luksroot`), then LVM (`ward/zroot`, `ward/swap`), then the `ward` ZFS pool.
Do not run disko or format these existing devices. The EFI filesystem is
`D04B-D453`. Wired networking is `enp3s0` (igc); both boot stages use its MAC
as the DHCP client identifier. The machine has a TPM 2.0.

## Recovery findings

The saved September 2026 journal showed the USB key partition timing out,
ZFS import exhausting its timeout before unlocking, and `/home` rejecting
mount(8) because `ward/keep/home` had a native ZFS mountpoint. The configuration
now prompts for the LUKS passphrase, pins the existing volume identity, and
orders pool import after `/dev/mapper/ward-zroot` exists.

NixOS owns the `/home` mount. Its dataset must have `mountpoint=legacy`:

```sh
sudo zfs set mountpoint=legacy ward/keep/home
```

Update the corresponding mountpoint column in
`/persist/etc/zfs/zfs-list.cache/ward` when migrating an existing system so the
ZFS generator does not also create `home.mount`. Other native ZFS datasets
retain their existing mountpoints and generator-managed mounts.

Recovery backups made on 2026-10-10 are the ZFS snapshots
`ward/temp/root@before-boot-repair-20261010` and
`ward/keep/persist@before-boot-repair-20261010`, plus the old EFI files and
ZFS mount cache under `/persist/ward-recovery-20261010/`. The root snapshot is
also saved there as `root-before-repair.zfs`, since normal root rollback removes
snapshots newer than `@blank`.

## First boot and Secure Boot transition

Use `.#ward` throughout installation and operation. Before first provisioning,
while Secure Boot is disabled, staged provisioning retains the public volume pin and defers sealed
recovery credentials and TPM policy creation. Enter the existing LUKS
passphrase at the console. There is no dependency on the former Samsung USB
key partition. Stage-2 SSH accepts the configured keys for root and cody;
cody has passwordless sudo. Password SSH is disabled.

Signing keys live at `/persist/secure-unlock/sbctl`; sbctl and Lanzaboote use
the same directory. Before changing firmware keys, run:

```sh
sudo sys backup-secure-boot
```

With firmware in Setup Mode and a backup secured, enroll using
`sudo sys setup-secure-boot`, then enable Secure Boot in firmware and boot the
signed Ward generation. Do not clear all firmware databases or discard
`dbx`. Verify `bootctl status` and `sbctl status` on the installed system.
Firmware enrollment and reboot are attended steps. During the October 2026
recovery, PK, KEK, db, and dbx were all absent; only SecureBoot/SetupMode
variables existed. Those variables were saved under the recovery backup's
`efivars/` directory. The strict backup command will report an incomplete backup
when databases are absent; do not interpret that as a reason to clear keys.

After booting with Secure Boot enabled, the service automatically generates
and seals the dedicated initrd SSH identity; no manual key generation is needed.
Rebuild the same `ward` output to include it in boot files. The hook seals the
key to the verified PCR 7 policy; only ciphertext enters the initrd. Recovery SSH starts on port
2222 when a passphrase is requested. Compare its fingerprint with
`/persist/secure-unlock/credstore.encrypted/ssh-host-key.pub` before connecting.
Ward uses wired recovery; a separate initrd Tailscale identity is not enrolled.

After booting the current pinned generation and retiring unpinned/old boot
entries from the measured-boot policy, run `sudo sys setup-luks-tpm-unlock`
to enroll automatic unlocking. This keeps passphrase recovery. See
[the shared procedure](../../docs/secure-unlock.md) for the PCR policy and
recovery requirements. No disk token is enrolled by a build or installation.

## Account passwords and persistent service state

Root and cody use the same shared password module as crow and warbler.
Their existing hashes are migrated from `/persist/etc/secret/{root,cody}.pass`
to root-owned mode-0600 `/persist/shadow.d/{root,cody}` (directory mode 0700).
The LUKS password is independent. `passwd`, `sudo passwd cody`, and
`sudo passwd root` persist successful changes through PAM across root resets
and rebuilds. No password or hash belongs in the repository or Nix store.

Hydra, PostgreSQL, and Grafana state now persist across root rollback, alongside
the existing persistent services. The obsolete Hydra `buildMachinesFiles`
option was removed; configuring new Hydra gRPC build agents is separate work.
Automatic flake upgrades are disabled during the staged boot migration.
Application/container versions and existing proxy routes are otherwise retained.

## Installed recovery checkpoint (2026-10-10)

Historical checkpoint, before the single-configuration workflow above:
generation 218 was the signed `ward-bootstrap` default, built from main
`5dde783` plus the ward changes. Both ward variants built successfully;
`nix flake check --no-build`, ward/crow assertions, and all 40 secure-unlock
and 7 password tests passed. Signatures on both retained UKIs and both
systemd-boot binaries were verified against ward's signing certificate.
Legacy loader entries whose kernel/initrd files were absent were moved to
`/persist/ward-recovery-20261010/retired-loader-entries/`.

The machine has not been rebooted; Secure Boot and TPM enrollment remain
pending. The previous generation 217 is retained but still has the original
USB-key startup configuration. Successful installation is not a boot test.
