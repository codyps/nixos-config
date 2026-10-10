# Media services and recovery

Robin's `robin/tank` hierarchy retains `/tank/...` mountpoints inside its LUKS
container. `media.nix` owns Audiobookshelf, Syncthing, Libation, and the tailnet
HTTP routes. A fresh installation requires restoring application data before
these routes can serve the existing libraries.

Preserve Robin's SSH/SOPS keys, machine ID, password hashes, and Tailscale
identity. Syncthing uses Finch's identity under
`/tank/syncthing/.config/syncthing`; never run that identity on both hosts
simultaneously. Sync and Dropbox folders use `receiveencrypted`, while Roms uses
`sendreceive`. Do not replace these modes with inferred defaults.

Audiobookshelf's state is `/var/lib/audiobookshelf`; its library paths are
`/tank/libation/data`, `/tank/books/personal`, and `/tank/books/kindle`.
Libation's container image policy rejects other image references; update the
declared digest and policy together for an intentional image upgrade.

## Recovery archives

`robin/finch-archive` retains Finch's persistent state, homes, root filesystem,
and Nix store. These are recovery archives, not Robin's active OS datasets.
They default to no mountpoint and `canmount=off`. The persist and Cody-home
archives are mounted read-only with `canmount=noauto` under the root-only
`/persist/finch-archive` directory for selective restoration. The archive includes
inactive PostgreSQL, Hydra, Storyteller state, logs, and old secrets.
Treat it as sensitive data. Do not recursively mount it over Robin's live paths.
The complete original home includes symlinks and files that conflict with
Robin's home; preserve Robin's live files when restoring selectively.

Source snapshots are named `@robin-migration-20260908` and
`@robin-migration-final-20260908`. Destination snapshots retain the state before
application activation. Snapshot manifests and the original DNS backup
`dns-before.json` are under `/persist/finch-migration`.
Do not rerun the initial receive/snapshot sequence over live datasets.

## Returning service to Finch

Finch's `tank` has `readonly=on`, inherited by every child. Runtime service masks
do not survive reboot: do not boot Finch into its old service configuration
while Robin runs the copied Syncthing identity.

Before returning Finch to service, stop Robin's writers and reconcile new
application state. Then set `zfs set readonly=off tank` on Finch and restore
the intended service masks and DNS. Never enable both Syncthing instances.
Take snapshots before application startup because services may migrate their
databases. Validate library/user/progress counts, media reads, Syncthing identity
and peers, folder modes, and HTTPS routes before switching DNS.
Preserve Finch's management hostname for recovery access.
