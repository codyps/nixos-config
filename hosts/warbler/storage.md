# Disk space

Warbler's root, `/nix`, `/home`, `/persist`, the AI container root, and its `/tmp`
share one encrypted 475 GiB Btrfs filesystem. Separate subvolumes and bind
mounts do not reserve capacity. The root reset at boot does not clean persistent
container homes, caches, or scratch storage.

## Encrypted SATA storage

The internal SATA SSD has a separate LUKS2 container labeled `warbler-actions`
and Btrfs filesystem labeled `warbler-actions-data`. Its host mount is
`/var/lib/warbler-sata`. The existing filesystem layout and unlock key carry over
without moving data.

### Actions VM storage

`/var/lib/actions-vm` is a compatibility bind mount of the SATA filesystem.
`build/` holds installer workspaces and `images/` holds published images.
`images/macos/` and `state/` are also bind-mounted at
`/var/lib/actions-vm-images` and `/var/lib/actions-vm-scaler-windows`,
respectively. macOS runtime state remains at `/var/lib/actions-vm-scaler`.

### AI container storage

`warbler-ai` mounts only its SATA directory, `containers/warbler-ai/`, at
`/mnt/sata`. The guest account `cody-ai` can write persistent data under
`/mnt/sata/work`, which shares free space with the Actions workloads. The
container's home and `/tmp` still use the system SSD.

### Unlock and recovery

The mounts use `nofail` so the host can boot without the SATA disk. The Actions
scalers and `warbler-ai` require their SATA storage before starting, so they
cannot write into fallback directories on the system SSD.

`actions-vm-storage.service` unlocks the volume after `/persist` is mounted,
using the root-only `/persist/var/lib/actions-vm-storage/key`. The key was generated
on Warbler and is never part of the repository, Nix store, or initrd. Losing that
key loses access to the runner volume; preserve it in trusted encrypted recovery
storage when backing up the host. The volume does not participate in early boot
unlock, signing, or measurements. The OS installation's disko configuration still
targets only the NVMe. Preserve the SATA SSD during reinstalls.

```sh
systemctl status actions-vm-storage
findmnt -M /var/lib/warbler-sata
findmnt -T /var/lib/actions-vm
findmnt -T /var/lib/actions-vm-images
findmnt -T /var/lib/actions-vm-scaler-windows
df -h /var/lib/warbler-sata
sudo nixos-container run warbler-ai -- findmnt -M /mnt/sata
```

## Inspect usage

`ncdu` is installed system-wide on Warbler, inside warbler-ai, and in the shared
Home Manager package set. Start with read-only scans:

```sh
df -h / /nix /persist /home
sudo btrfs filesystem usage -T /
sudo ncdu -x -r /persist/var/lib
sudo ncdu -x -r /home
# Inside warbler-ai:
ncdu -x -r "$HOME"
ncdu -x -r /tmp
```

Scan the backing directory under `/persist` once; scanning both `/persist/var`
and `/var` counts the same files twice. `du` and ncdu can overcount shared
Btrfs extents and do not account for compression like filesystem usage does.
Use `df` and `btrfs filesystem usage` to measure actual headroom; directory
sizes identify where to investigate, rather than predict bytes freed.
If deletion does not recover expected capacity, inspect shared snapshots,
`btrfs subvolume list /`, and deleted files still held open (`sudo lsof +L1`,
if lsof is available).

## Abandoned Git packs

Interrupted fetches and repacks can leave large `tmp_pack_*` files under a
repository's `.git/objects/pack`. Use `git count-objects -vH` to identify garbage
and inspect its size. Before deleting temporary packs, check again for active
Git/index-pack processes and open file descriptors; retries can create new
files while an investigation is in progress. Preserve valid packs, loose
objects, and the rest of `.git`.

## Prevention and recovery

Warbler runs Nix GC daily, deleting generations older than 14 days while keeping
the current generation. Nix also attempts collection of unrooted store paths
when free space drops below 20 GiB during builds, aiming for 40 GiB free.
GC roots, including active development shells, still protect paths; these
thresholds cannot reserve capacity or remove project data. Inspect roots with
`sudo nix-store --gc --print-roots`. Never delete `/nix/store` files manually.

Journals are limited to 1 GiB on the host and 512 MiB in the AI container, with
4 GiB keep-free targets. This only limits journal growth; it cannot guarantee
filesystem headroom. Existing disk-backed AI scratch retains the standard
10-day tmpfiles policy, which uses file timestamps and is not a space quota.

The shared [mbx configuration](../../config/mbx.toml) enables automatic collection
and managed targets, with a 10 GiB action-store target and 20 GiB combined
action-store/managed-target target. Home Manager and both AI accounts use the
same upstream shim and direnv priority handling. Active builds can exceed the
targets. Existing ordinary Cargo target directories are not automatically moved
or deleted by installing the shim.

Review project artifact retention and unused scratch/build directories with
their owners. Use shallow or blob-filtered vendor fetches where possible;
repeated retries can accumulate abandoned output, and a full repack needs
additional working space. Stop active builds before cleaning their outputs.
Prefer each tool's cleanup command and an explicit retention policy over
indiscriminate age-based deletion of project trees. Treat live application
state, recovery archives, and active VM images separately from disposable
build caches.

Keep at least 40 GiB of working headroom and check before large firmware/VM
builds. If this workload regularly needs its current data, add capacity or move
build artifacts/caches to a separate filesystem. Btrfs subvolumes alone do not
isolate space; quotas or a dedicated filesystem can contain an AI/build workload,
but require a separate, reviewed migration. An external disk-free alert would
also catch growth between interactive sessions; journald limits and Nix GC are
not an alerting system.

## Incremental deduplication

`dedupit.service` starts at boot and waits an hour after each run finishes
before retrying. The native Rust service mounts cryptroot's
Btrfs top level privately and scans every subvolume, including `/nix`, `/home`,
`/persist`, container files, and scratch data. The private writable view permits
kernel-verified sharing in the Nix store without changing its normal read-only
mount. Virtual filesystems and external mounts are outside this view. File names,
inodes, contents, and independent write behavior are preserved.

The package and NixOS module come from the `dedupit` flake input.
The input is pinned to the `main` branch on GitHub. Fetching this
private source requires GitHub SSH access when it is not already cached. It uses
native generation-based discovery, whole-file and 1 MiB range sharing, and a
persistent `/var/lib/dedupit/filesystem.sqlite` index. The previous container-only
`ai.sqlite` index is retained; its roots differ and cannot be reused for this scan.
The new index requires additional disk space. Dedupit excludes its own active
index and sidecar files by inode, including through the alternate mount path.
The index uses NOCOW storage, matching Crow, to avoid Btrfs copy-on-write overhead
for SQLite updates. Converting an existing COW index requires stopping the
service and running `sudo sys dedupit-compact` before restarting it. Compaction
preserves scan progress and needs space for both the original and replacement
indexes until validation and the atomic swap finish.

Busy executables and other failed sharing jobs remain pending for the next run.
Changed files are rescanned. Completed runs with per-file errors and fatal scan
failures are recorded in the native service's status and retried after an hour.
Process failures are restarted by systemd after five minutes. Persistent
unsupported/invalid requests can recur; inspect the saved error list if failures continue.

The service runs at idle I/O priority and nice 19 with a 2 GiB memory soft limit
and 4 GiB hard limit. The Rust process checks available space every 30 seconds
and pauses below 5 GiB, retaining committed progress. That polling guard is not a quota;
rapid allocation or Btrfs metadata exhaustion can still cause ENOSPC. A later
run resumes the same index. Stopping the unit also leaves committed work reusable.

```sh
systemctl status dedupit.service
sudo journalctl -u dedupit.service
sudo sys dedupit-stats
sudo sys dedupit-stats --json
sudo systemctl start dedupit.service
sudo systemctl stop dedupit.service
```

The result file contains the last complete JSON report, including per-file
errors; an interrupted run leaves that report intact and writes current status
separately. Reports and the index are root-only. Reported deduplicated bytes are
logical bytes accepted by the kernel, not physical space freed.

## Scheduled Btrfs balance

All NixOS configurations import `nixos-modules/btrfs-balance.nix`. Hosts with a
configured Btrfs filesystem enable `btrfs-balance.timer` automatically. It runs
weekly with up to two hours of jitter and catches up after missed runs. It
inspects configured mount points, skips unmounted or read-only filesystems, and
balances each mounted filesystem UUID once even when several subvolumes are
mounted separately.

Maintenance first reclaims completely empty data/metadata block groups, then
relocates at most eight data block groups that are no more than 50% occupied.
It preserves allocation profiles and extent sharing. An existing running balance
is left alone. Errors fail the unit while allowing other filesystems to proceed;
ENOSPC is not hidden or escalated into a broader balance. The timer runs at idle
I/O priority and nice 19.

```sh
systemctl status btrfs-balance.timer btrfs-balance.service
sudo journalctl -u btrfs-balance.service
sudo systemctl start btrfs-balance.service
```

Override `services.btrfs.autoBalance.interval` to change the schedule, or set
`services.btrfs.autoBalance.enable = false` to opt out. This is preventive
maintenance; an already metadata-starved filesystem may first need enough
metadata/workspace freed for relocation to succeed. A full, unfiltered balance
is not part of the scheduled policy.

### Metadata recovery, 2026-10-30

The SSD had about 40 GiB free inside data block groups but only 1 MiB of
unallocated device space. Metadata occupied about 13.99 of 14.5 GiB, with almost
all remaining space needed for the 512 MiB emergency reserve. New files and
renames failed with ENOSPC despite the free space reported by `df`.

An initial empty-group reclaim found nothing. After syncing pending writes, a
single data group at no more than 10% occupancy relocated successfully. Btrfs
immediately used that allocation to grow metadata. A further bounded pass of
four data groups at no more than 40% occupancy completed successfully. Metadata
allocation reached 16 GiB with about 13.81 GiB used, leaving roughly 2.2 GiB of
metadata headroom plus 1 GiB of unallocated device space. No profile conversion
or unfiltered balance was needed. A create/write/rename/delete check passed
following recovery.

After configuration validation, running the scheduled policy once reclaimed
eight more data groups with the 50% occupancy limit. The final measured metadata
allocation was 17.5 GiB with about 14.06 GiB used, leaving roughly 3.4 GiB of
metadata headroom and 3 GiB unallocated on the device. No balance remained active.
