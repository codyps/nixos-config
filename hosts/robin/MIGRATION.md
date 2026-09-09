# Finch migration — 2026-09-08

## Scope and identity

Finch's `tank` hierarchy was replicated to `robin/tank`, retaining
`/tank/...` mountpoints. All data remains inside Robin's LUKS container.
`media.nix` owns Audiobookshelf, Syncthing, Libation and the tailnet HTTP routes.

Preserve Robin's SSH/SOPS keys, machine ID, password hashes, and Tailscale
identity. Syncthing is different: retain Finch's config, certificates and index
under `/tank/syncthing/.config/syncthing`, and never run that identity on both
hosts simultaneously. Finch's Sync and Dropbox folders are `receiveencrypted`;
Roms is `sendreceive`. Do not replace these modes with inferred defaults.

Audiobookshelf's state is `/var/lib/audiobookshelf`; its library paths are
`/tank/libation/data`, `/tank/books/personal`, and `/tank/books/kindle`.
The source database has 2 users, 310 library items, 2 media-progress records,
and 2 playback sessions; its integrity check passes. Its UID/GID are 992/990.
Syncthing uses UID/GID 237/237. Libation's image is pinned to Finch's deployed
digest so container upgrades remain separate from the move. The container
image policy rejects other image references; update the declared digest and
policy together for an intentional image upgrade.

## Source freeze and recovery copies

Source snapshots are named `@robin-migration-20260908`. The source services
Audiobookshelf and Syncthing, Libation service/timer, and Nix upgrade/optimise/GC
and Podman prune timers are runtime-masked during migration. Runtime masks do
not survive reboot: do not reboot Finch into its old service configuration
while Robin runs the copied Syncthing identity. Finch’s `tank` also has
`readonly=on`, inherited by every child, so the data freeze survives reboot.
To return Finch to service, first stop Robin’s writers and reconcile any new
application state, then set `zfs set readonly=off tank` on Finch and restore
the intended service masks and DNS. Do not enable both Syncthing instances.

`robin/finch-archive` retains Finch's persistent state, homes, root filesystem,
and Nix store. These are recovery archives, not Robin's active OS datasets.
They default to no mountpoint and `canmount=off`. The persist and Cody-home
archives are mounted read-only with `canmount=noauto` under the root-only
`/persist/finch-archive` directory for selective restoration. This archive also
retains inactive PostgreSQL 14, Hydra, Storyteller state, logs, and old secrets.
Treat it as sensitive data. Do not recursively mount it over Robin's live paths.

Regular Cody-home files were merged with `rsync --no-links --ignore-existing`;
Robin's existing files and Home Manager symlinks take precedence. The complete
original home, including symlinks and conflicting files, remains in the archive.

## Transfer monitoring

The completed direct transfers ran as transient systemd services on Robin:

- `finch-libation-transfer`: resumed Libation snapshot stream.
- `finch-remaining-transfer`: Syncthing, local, Storyteller, and tmp datasets.
- `finch-state-migration`: recursive send of `rpool/safe` (completed).
- `finch-os-copy`: root filesystem, then Nix store archive (completed).
- `finch-migration-finish`: guarded validation, activation, and audiobook DNS cutover.

The initial `finch-tank-migration` stream completed books and was deliberately
stopped partway through Libation to split the remaining work into two streams.
Libation resumes from its receive token; completed datasets are not recopied.

The finisher and its snapshot/DNS manifests are root-only files under
`/persist/finch-migration`. It writes `activation.log` and, only after successful
public HTTPS checks, `completed.json`. After the base copies, it sends a final
incremental snapshot named `@robin-migration-final-20260908` to include
inspection-related atime metadata. It excludes the source’s read-only property
from this receive and explicitly makes Robin’s active data datasets writable.
Failures stop the sequence; inspect its journal before attempting recovery. The original DNS records are retained in
`dns-before.json`. It changes only the two active audiobook service names.

Inspect their journals and `systemctl show` status, and compare received
snapshot GUIDs against Finch before activation. Receives use `-u -s` so data
stays unmounted and interrupted datasets retain a resume token. A resumed
recursive stream may require separately sending remaining descendants;
never restart a full receive with destructive force flags over completed data.

## Cutover requirements

Build and copy the Robin system closure using the Linux builder. Do not run
Disko's formatting script on either installed host. Set received media dataset
mountpoints explicitly and activate only after the complete hierarchy exists.
Keep source snapshots and take destination snapshots before first application
startup, because Audiobookshelf and Syncthing may migrate their databases.

Validate library/user/progress counts, media reads, Syncthing identity and peers,
folder modes, Libation's completion, and HTTPS routes before switching DNS.
The two public audiobook A records now point to Robin (153.75.248.236), with
Cloudflare proxying retained. Their old AAAA origins were removed because Robin
has public IPv4 only. Preserve Finch's
management hostname for rollback. Storyteller is inactive and its saved data
must not be mistaken for a deployed service.

Robin's exit-node advertisement has been enabled and its tailnet routing
permission was approved by the user and saved in the Tailscale admin console.
Clients selecting Finch as their exit node must select Robin explicitly.

## Completed cutover

Public DNS and HTTPS cutover completed on 2026-09-08 at 18:42 EDT.
Final activated system: `/nix/store/rkc8c7ya72c7s3bs5amsjv4jldgsz17k-nixos-system-robin-26.11.20260905.c043004`.
All 22 base snapshot GUIDs and all 15 final media snapshot GUIDs were verified.
Approximately 169 GiB of media plus the OS/persistent-state archives were copied.
Destination snapshots retain the state from before application activation.

Audiobookshelf 2.36.0 retains 2 users, 1 library, 310 library items, 2 progress
records, and 2 playback sessions; SQLite integrity and original record IDs pass.
Syncthing 2.1.3 completed its SQLite migration, preserves the original identity
and folder modes, and has connected peers without folder errors. HTTPS routes
for both public services and the tailnet Syncthing/Roms paths were checked,
including byte comparison of a media range.

The original finisher stopped when Syncthing's temporary database-migration GUI
returned a non-JSON response. Its retry handler now includes JSONDecodeError.
Recovery resumed at validation, preserving all data written after activation;
do not rerun the initial receive/snapshot sequence over the live datasets.
The completion record and original DNS backup are in `/persist/finch-migration`.

Caddy explicitly uses `get_certificate tailscale` for the tailnet hostname.
The parent Syncthing directory grants Caddy traversal through a tmpfiles ACL,
including an explicit ACL mask so user-home mode resets cannot disable it.
The private `.config` directory remains mode 0700 and inaccessible to Caddy.

Libation's timer runs successfully and account scans process 170 books.
One book-processing error remains in Libation; the container reports overall
success despite that application error. This is not a failed data transfer.
Inactive Storyteller/PostgreSQL/Hydra state is retained for recovery, not enabled.
Finch has not been destroyed or decommissioned; its management DNS is unchanged.

The deployment preserves the package pins used for the initial migration.
Concurrent workspace changes to package pins, SSH, and Nix cache configuration
were excluded from the isolated deployment build.
