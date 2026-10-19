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

## Observed usage, 2026-10-19

The filesystem was 98% full with about 14 GiB available. Directory sizes below
are approximate allocated bytes reported by `du`; they are not additive physical
usage, and parent rows include their children.

| Location | Size | Detail |
| --- | ---: | --- |
| AI home, `/persist/var/lib/nixos-containers/ai/home/cody-ai` | 470 GiB | Main consumer |
| AI `~/p/trimui-firmware` | 319 GiB | `.git` 192 GiB, artifacts 99 GiB, shared 29 GiB |
| AI `~/.cache` | 77 GiB | Bazel 70 GiB; mbx 4.7 GiB; uv 2.2 GiB |
| AI `/tmp`, backed by `/persist/var/lib/warbler-ai/tmp` | 59 GiB | `wasm2go-optimizer` 37 GiB |
| AI `~/p/zpl-font-extract` | 24 GiB | `_font-work` 22 GiB |
| AI `~/.codex` | 17 GiB | Contains live application state; review before cleanup |
| macOS VM image directory | 33 GiB | Keep the active image required by the runner |
| Legacy host `/home/cody-ai` | 19 GiB | Retained for recovery |
| `/nix` | 20 GiB | Overnight GC had already freed 31.3 GiB |
| Host journal | 801 MiB | Not the primary cause |

The initial inspection did not delete files.

`git count-objects -vH` identified 27 `tmp_pack_*` files as garbage, totaling
191.70 GiB, with zero completed packs. Their modification times ran from the
evening of October 18 through 09:44 on October 19. At inspection, no process
had an open descriptor to these files, and no Git/index-pack process was running.
They appeared to be abandoned fetch/repack output. Recheck for writers immediately
before cleaning similar files; removing `.git`, valid packs, or loose objects
is not equivalent.

A later check found 28 temporary packs totaling 203.82 GiB, including a new pack
modified at 12:30. This growth suggests interrupted or retried Git operations
were continuing to accumulate output. User cleanup elsewhere brought free space
to about 38 GiB by the end of validation.

After user approval, a fresh process and file-descriptor check found no writers.
All 28 temporary packs were removed, recovering 203.82 GiB. After a Btrfs sync,
available space rose from 37.22 GiB to 241.04 GiB, with the filesystem about 49%
used and no temporary packs remaining. The configuration was then activated;
host, container, and checked user managers had no failed services, and the Codex
daemon responded. Both login shells and user services passed the mbx setup check.

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

After the pack cleanup, review `trimui-firmware` artifact retention with its
owner and use shallow or blob-filtered vendor fetches where possible.
Repeatedly retrying a large fetch without removing its abandoned output can
consume the remaining space. A full repack also needs temporary working space;
avoid starting one on a nearly full disk. Do not delete `.git` as a cache.
Review the 37 GiB optimizer scratch
workspace and unused Bazel output bases with their owners; stop their builds
before cleaning. Prefer each tool's cleanup command and a documented retention
policy over indiscriminate age-based deletion of project trees.

Keep at least 40 GiB of working headroom and check before large firmware/VM
builds. If this workload regularly needs its current data, add capacity or move
build artifacts/caches to a separate filesystem. Btrfs subvolumes alone do not
isolate space; quotas or a dedicated filesystem can contain an AI/build workload,
but require a separate, reviewed migration. An external disk-free alert would
also catch growth between interactive sessions; journald limits and Nix GC are
not an alerting system.
