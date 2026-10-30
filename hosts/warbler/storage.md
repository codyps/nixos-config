# Disk space

Warbler's root, `/nix`, `/home`, `/persist`, the AI container, and its `/tmp`
share one encrypted 475 GiB Btrfs filesystem. Separate subvolumes and bind
mounts do not reserve capacity. The root reset at boot does not clean persistent
container homes, caches, or scratch storage.

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
