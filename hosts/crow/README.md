# Crow

Build and rebuild directly from this repository with `--flake .#crow`.
[Provision local hardware identities](../../docs/hardware-identities.md) once
before installation or activation. Source changes need no provisioning refresh;
identifiers remain in local state and are appended before boot-image signing.

Crow is an x86_64 AMD machine with 64 GB RAM, UEFI, and TPM 2.0.
Wi-Fi is `wlp6s0` (`mt7921e`). The installation disk is a WD_BLACK SN850X
4000GB; its exact device selector is configured in `disko.nix`.

## Power LED

`sudo sys power-led-brightness 10` changes the power button LED immediately;
values range from 0 to 255. This changes live brightness without saving a BIOS
default. `sudo sys power-led-brightness --probe` reads controller status, not
the current brightness. The command is installed after rebuilding and activating
Crow's configuration.

To apply a separate value during Linux startup, set
`hardware.msA2.powerLed.bootBrightness = 10;` in the host configuration. The
default is `null`, which leaves the BIOS-selected brightness in place. A boot
value takes effect after the encrypted root is unlocked; POST and the recovery
initrd retain the BIOS setting. Changing the live brightness does not change
this startup value.

The tested MS-A2 BIOS 1.03 (2026-04-01, Ryzen 9000) passes `Setup[0x72]` to
the embedded controller: wait for input-buffer bit 1 to clear on port `0x6c`,
write command `0xdf` there, wait again, then write the PWM byte to port `0x68`.
This sequence comes from the `OemECHwMonitor` PEI module in the
[official vendor firmware](https://support.minisforum.com/pages/product-info).
The helper serializes its invocations and aborts on readiness timeouts. No
brightness readback command is established. The BIOS `Setup` variable is absent
from Linux's runtime EFI variable interface on this machine, so changing the
saved firmware default directly from Linux is not supported by this helper.

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

`volume-identity.nix` reads the installed volume identity from the local input. Use `.#crow`
throughout: staged provisioning defers credentials and TPM policy until the
pinned host boots with Secure Boot enabled. The first unlock is at the console.
Signing keys must exist before boot-file installation. Neither the configuration
nor a rebuild enrolls firmware keys or a TPM disk token. See the
[shared staged workflow](../../docs/secure-unlock.md#staged-provisioning-with-one-configuration).

## Ethernet

Ethernet interfaces named `en*` or `eth*` use systemd-networkd for DHCP,
IPv6 router advertisements, and DNS through resolved. Wired routes have metric
100 and Wi-Fi routes have metric 600, so Ethernet is preferred while connected.
An unplugged Ethernet cable does not hold up network-online. The AI container
also prefers Ethernet and retains its separate Wi-Fi LAN connection as fallback.

After activating the configuration on Crow, use `networkctl status` to verify
the wired interface has an address, and `ip route` and `ip -6 route` to verify
the preferred routes.

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

## OpenCode server

`opencode-server.service` runs `opencode serve` as `cody` on
`127.0.0.1:49375`. Tailscale Serve exposes it at
`https://crow.little-moth.ts.net:8443/` so the node's HTTPS port 443 stays
available for other services. `http://crow.little-moth.ts.net:49375` remains
available as a direct TCP endpoint. Neither needs a firewall change. The
password is in `secrets.yaml`; read it with
`sudo cat /run/secrets/opencode-password`. `restartUnits` restarts the daemon
when either secret changes.

Connect a TUI or another OpenCode client with:

```sh
OPENCODE_PASSWORD="$(sudo cat /run/secrets/opencode-password)" \
  opencode --server https://crow.little-moth.ts.net:8443
```

For a browser or app pairing link, run:

```sh
sudo sys opencode-pair host
```

`opencode pair` only pairs the caller's shared background service and
rejects `--server`, so the helper mints the single-use code through the
running server's pairing API instead and prints a
`https://crow.little-moth.ts.net:8443/auth/connect/...` link.

OpenCode reads managed configuration from `/etc/opencode/opencode.json`
(rendered from `services.opencode.settings`) with the highest precedence.
OpenCode does not rewrite that file. User-level settings live in
`~/.config/opencode/cli.json` and the managed background service's
`service.json`; in-app changes to the global `shell` setting are written to the
user's `opencode.json(c)`, which managed settings still override. The Strata
API key is SOPS-encrypted in `secrets.yaml`; the managed config reads it from
`/run/secrets/strata-api-key`. Rotating either `strata-api-key` or
`opencode-password` restarts `opencode-server.service`.

### Sandbox: per-project tool execution in the AI container

The server itself stays on Crow; provider traffic, managed settings,
sessions, and secrets never enter the container; and the sandbox is
strictly opt-in per project. The system configuration never loads the
plugin; `opencode-sandbox.nix` only builds it and registers admin
commands:

```sh
sys opencode-sandbox-enable /home/cody/<project>   # sandbox sessions in that project
sys opencode-sandbox-disable /home/cody/<project>  # un-sandbox them again
sys opencode-sandbox-check                          # probe the SSH channel to crow-ai
```

`enable` writes a `plugins` entry into `<project>/.opencode/opencode.json`;
`disable` removes it. OpenCode hot-reloads project configuration, so both
take effect immediately, with no rebuild. Only sessions anchored inside an
enabled project are affected.

In an enabled project, the session's `shell` tool runs as
`cody-ai@10.80.0.2` over SSH: a `create.before` hook rewrites each command
to `ssh`, keeping the native output handling, timeouts, and background
semantics intact. The host-executing filesystem tools (`read`, `write`,
`edit`, `glob`, `grep`, `patch`, and the worktree create/remove tools) are
removed for enabled projects; the model performs file operations through
the sandboxed shell (heredocs, `cat`, `sed`). Orchestration tools
(`question`, `skill`, `subagent`) stay host-side and do not touch the
filesystem; subagents inherit the sandboxed toolset. When the container is
unreachable, sandboxed tools fail closed; they never fall back to
executing on the host.

Connections authenticate with cody's host key (`~/.ssh/id_ed25519`),
which `cody-ai` accepts through the shared authorized keys. The
container's host key is trusted on first use and pinned in
`/var/lib/opencode/sandbox-known-hosts`; if the container is ever rebuilt
with a fresh host key, remove that file and restart `opencode-server`.

Host session directories map onto the container's workspace root:
`/home/cody/<project>` becomes `/home/cody-ai/workspaces/<project>` (the
shell tool creates the mapped directory on first use), and absolute
container paths pass through unchanged.

Known limitations: the host-side VCS view (change summaries, diffs)
reflects the session's host anchor directory rather than the container
workspace; ask the agent to run `git` commands instead; file operations
go through shell commands rather than dedicated file tools, so reads do
not come pre-numbered and edits are plain text replacement; sandboxed
sessions lose the `patch` and worktree create/remove tools. When a
newer OpenCode allows declaring per-tool output schemas, dedicated
SSH-backed file tools can return.

### OpenCode server in the AI container

A second OpenCode server runs entirely inside `crow-ai` as `cody-ai`,
listening on the private container link at `10.80.0.2:49375`. Everything
it does happens in the container by construction; the sandbox plugin is
not loaded there. Cody's OpenCode plugins do load there: Crow's
`/home/cody/.config/opencode/plugins` is bind-mounted read-only at
`/run/opencode-plugins`, and `cody-ai`'s own
`~/.config/opencode/opencode.json` lists them; it is seeded by guest
activation if missing, then editable, and deliberately outside the
managed `/etc/opencode` settings. The host exposes it at
`https://crow.little-moth.ts.net:8444` (the host server keeps 8443), and
tailnet clients can also reach `http://10.80.0.2:49375` directly through
the advertised `10.80.0.2/32` route. It uses the same `opencode-password`
secret as the host server:

```sh
OPENCODE_PASSWORD="$(sudo cat /run/secrets/opencode-password)" \
  opencode --server https://crow.little-moth.ts.net:8444
```

For a pairing link to the container server, run `sudo sys opencode-pair
container`, which prints a one-time
`https://crow.little-moth.ts.net:8444/auth/connect/...` link.

Both secrets stay SOPS-encrypted on Crow (`secrets.yaml`) and are staged
by `crow-ai-opencode-secrets.service` into
`/var/lib/crow-ai/opencode-secrets` with container-mapped ownership, then
bind-mounted read-only and id-mapped into the guest at
`/run/opencode-secrets`. Rotating either `strata-api-key` or
`opencode-password` restages the files and restarts the in-container
daemon via `systemctl --machine=crow-ai`; the host relays need no restart.
Edit plugin code as `cody` on Crow and apply it with
`systemctl --machine=crow-ai try-restart opencode-server.service`; edit
the plugin list inside the container as `cody-ai` the same way. The
bind mount set is a container boundary: changes require restarting
`container@crow-ai`, which interrupts guest sessions.

The container has no tailscaled, so MagicDNS names such as the Strata
backend are answered by Crow's resolver on `10.80.0.1:53` on the private
link, and `100.64.0.0/10` routes through Crow. Return traffic rides the
advertised `10.80.0.2/32` subnet route; no NAT is involved. After
activation, verify from Crow with
`systemd-run -M crow-ai --pipe getent hosts desktop-lgmeaa4.little-moth.ts.net`.

Choose the host server when you want provider traffic and configuration
on Crow with optional per-project sandboxing (above); choose this one
when the whole session, tools included, should live in the container.

## Backups

Restic backs up `/persist` and `/home` to the TrueNAS REST server. The
endpoint (`https://restic.terni.einic.org/cody/1`) and username are
SOPS-encrypted in `backup-secrets.yaml` (age-only to Crow's SSH identity,
like `hindsight-secrets.json`); edit them with `sops hosts/crow/backup-secrets.yaml`.
`restic-backups-truenas.timer` runs the nightly backup at 02:30 with up
to 45 minutes of randomized delay, catching up after downtime; backup
runs wait up to 30 minutes for the repository lock instead of failing.
Retention is a separate weekly job, `restic-backups-truenas-prune.timer`
(Sunday 04:30, up to 15 minutes of delay): forget/prune takes an
exclusive lock over the shared repository, so it is staggered away from
the backup windows, host-scoped with `--host crow`, and waits up to 60
minutes for the lock. It keeps 7 daily, 5 weekly, 12 monthly, and 3
yearly snapshots. `restic-truenas` and `restic-truenas-prune` are
interactive wrappers with the same environment as their services, and
`sudo sys backup-now` starts a backup immediately.

Two credentials never leave Crow in any form, not even encrypted in Git:
the restic repository password (`restic-password`) and the REST-server
basic-auth password (`rest-server-password`). `sudo sys setup-backup-keys
generate` provisions any missing one as TPM-sealed ciphertext in
`/persist/credstore.encrypted`, bound to PCR 7 exactly like the
secure-unlock credentials, and prints each generated value once; store
both in a password manager immediately; they cannot be recovered from
Crow's disks or the repository alone. To reuse credentials that already
exist elsewhere (a repository password from an existing restic
repository, or a basic-auth password already configured on TrueNAS),
seal them instead with `sudo sys setup-backup-keys enter restic-password`
or `sudo sys setup-backup-keys enter rest-server-password` (each value is
read hidden from the terminal, entered twice, and sealed verbatim).
`sudo sys setup-backup-keys show` re-prints sealed values.

Snapshots carry backrest-compatible tags: `plan:crow` and
`created-by:crow` (backrest identifies snapshots via `plan:` and
`created-by:` tags, and accepts them on externally created snapshots).
Backrest's per-plan forget only selects snapshots tagged with its own
plan or instance, so Crow's snapshots are invisible to it, but a
repo-level scheduled forget policy in backrest applies to every snapshot
in the repository, including Crow's; keep that policy disabled on the
TrueNAS repo or coordinate it with this one. List this host's snapshots
with `restic-truenas snapshots --host crow` or
`restic-truenas snapshots --tag created-by:crow`.

At boot, `restic-backup-credentials.service` unseals both credentials
through the TPM (Secure Boot must be enabled, and the service fails
closed otherwise) and composes root-only
`/run/restic-backup-credentials/{restic-password,repository}`. Until
both sealed credentials exist, that service and the backup unit skip
through path conditions, keeping activation and boot clean while backups
stay refused. The backup unit starts only after that service and after
the daily `postgresqlBackup` dump. Excluded from backups: the live PostgreSQL
cluster (restore from the captured dumps in `/var/lib/postgresql-backups`),
the TPM credstores, the rebuildable dedupit index, re-downloadable
Hindsight model caches, and `~/.cache`.

On the TrueNAS side, run a restic REST server reachable at the endpoint
above with basic-auth user `cody` matching the sealed password, a valid
TLS certificate (restic rejects self-signed certificates by default), and
space for the retention policy; an append-only server breaks
forget/prune. If Secure Boot policy changes (PCR 7) or the TPM is cleared,
unsealing fails: re-seal both values from the password manager with
`sudo sys setup-backup-keys enter …`. Restores need only repository
access plus the two credentials, for example
`sudo restic-truenas restore latest --target /tmp/restore`.

## AI container

`crow-ai` and `warbler-ai` share [the AI container module](../../nixos-modules/ai-container),
including guest tools, user services, persistent home, and
`cody-ai` user, with passwordless sudo enabled specifically on Crow.
Crow has no host-level `cody-ai` account or legacy
sandbox service. The container uses veth addresses `10.80.0.1` (host) and
`10.80.0.2` (guest) for management. L2 ipvlans on Ethernet (`enp3s0`) and Wi-Fi
provide separate LAN DHCP leases, broadcast/multicast access, and no NAT.
Each shares its parent interface's MAC; the guest uses a DUID DHCP client
identifier to distinguish its leases from the host. Ethernet routes have metric
100 and Wi-Fi routes have metric 600.
DNS and the default route come from the LAN.

The container is named `crow-ai`, not `ai`, because systemd-machined publishes
every registered machine name as an authoritative DNS domain. A machine named
`ai` makes lookups under the real `.ai` TLD, including `z.ai` and `api.z.ai`,
return NXDOMAIN. The first switch from the old name stops `container@ai` via a
unit conflict and migrates `/var/lib/nixos-containers/ai` to
`/var/lib/nixos-containers/crow-ai` before the renamed container starts.

Applying this boundary change requires restarting `container@crow-ai`, interrupting
guest sessions. Verify distinct LAN leases on `iv-enp3s0` and `iv-wlp6s0`, the LAN default
route, DNS, and broadcast/multicast exchange with another LAN machine after
activation. Wi-Fi/AP and DHCP compatibility require live testing on Crow.

After authenticating Crow to Tailscale, access the guest with
`ssh -p 2223 cody-ai@crow`. On the local Wi-Fi network, use
`ssh -p 2223 cody-ai@<crow-lan-ip>`. The firewall allows the SSH proxy on
Crow's Ethernet, Wi-Fi, and Tailscale interfaces. The host also advertises
`10.80.0.2/32`; accessing that route needs
approval in the tailnet. This configuration does not register a `crow-ai`
Tailscale node or create DNS records. From Crow itself, use
`ssh cody-ai@10.80.0.2`.

Authenticate AI providers within the new container. No existing Warbler
account, provider credentials, or working files are copied. Manage Codex with
`sys update-codex` and `sys restart-codex` as the guest user.

Rootless Docker runs as `cody-ai` through the lingering `docker.service` user
unit. Shells and user services use `/run/user/1001/docker.sock`; images and
volumes persist under `/home/cody-ai/.local/share/docker`. After rebuilding,
restart `container@crow-ai` on Crow to apply the TUN device access (interrupting guest
sessions). In the guest, verify `systemctl --user status docker`, `docker info`,
and `docker run --rm hello-world`. Docker info should list `rootless` under
Security Options. Existing user services may need restarting to pick up
`DOCKER_HOST`.

FUSE mounts are available to the guest user through `/dev/fuse` and the
`fusermount3` helper. The host loads the FUSE kernel module and passes the
device into the container. After rebuilding, restart `container@crow-ai` on Crow
to apply this device access (interrupting guest sessions). In the guest,
verify `test -r /dev/fuse && test -w /dev/fuse` and `fusermount3 --version`,
then test a mount with the intended FUSE application.

USB devices use normal kernel device paths with read/write access for
`cody-ai`: `/dev/sdb1`, `/dev/hidraw0`, `/dev/ttyUSB0`, `/dev/ttyACM0`, and
`/dev/input/event0`, for example. Raw USB nodes are directly available under
`/dev/bus/usb`. Host udev maintains a USB-only mirror, bound read-only at
`/run/crow-ai-usb-devices`; a guest service maintains normal `/dev` links to
its block and character nodes, including hotplug removal, within about half
a second. Existing container devices are never overwritten. The raw USB
directory is a direct bind of the mirror's USB bus directory. Read-only
binds protect device-node metadata while permitting read/write device I/O.
Persistent udev aliases such as `/dev/serial/by-id` are not mirrored.
Internal disks are not mirrored. This grants direct write access to USB disks;
coordinate host and guest use to avoid corrupting filesystems mounted on the
host.

`cody-ai` has passwordless sudo for all commands in Crow's container. Check
with `sudo -n id`. Sudo grants root inside the guest's user namespace.
The guest's `mount` and `umount` wrappers delegate USB filesystem operations
to `crow-ai-usb-mount.service` on the host:

```sh
sudo mkdir -p /mnt/usb
sudo mount /dev/sdb1 /mnt/usb
sudo umount /mnt/usb
```

Substitute the actual device node. `sudo mount -r ...` mounts read-only;
`-t TYPE` and `-o ro,rw,noatime,relatime,nosuid,nodev,noexec` are supported
(choose either ro or rw, and either noatime or relatime). Unmounting by the
`/dev` source path also works. Destinations must be existing empty
directories under `/mnt` or `/media`, with no symlinks or `..` components.
Other mount operations use the regular util-linux commands locally.

The broker authenticates the mapped root UID and Crow AI's main user/mount
namespaces using Unix socket peer credentials. It verifies USB ancestry in
host sysfs and rejects devices used by host mounts (including Btrfs members
and mounted sibling partitions), swap, device-mapper/RAID holders, and loop
devices. Supported types are ext2/3/4, Btrfs, XFS, FAT, exFAT, NTFS via ntfs3,
ISO9660, and UDF, subject to kernel support; POSIX filesystems require
ID-mapped mounting support. It always sets `nosuid,nodev,noexec`; arbitrary
options, bind/remount operations, network filesystems, encrypted/LVM/RAID
volumes, external journals, multi-device/seed Btrfs, Btrfs with metadata-UUID
remapping or an already registered host UUID, and forced/lazy unmount requests
are rejected.

The host creates a detached mount and attaches it directly into the guest
mount namespace using pinned descriptors. Guest paths are opened with
`openat2` confined to the guest root and without symlink traversal. No host
mount propagation channel is shared. The helper records mount IDs privately
under `/run/crow-ai-usb-mount-state` and only unmounts its own recorded mounts.
It never runs guest executables as host root. Disk ownership is not rewritten:
POSIX owners are mapped to guest IDs; FAT-style volumes use `cody-ai` ownership.
Normal busy mounts fail without lazy detaching. Close files/processes and
unmount before unplugging; do not move or overmount managed mountpoints.

Native USB filesystems still use the shared host kernel, including its
filesystem parsers. Host-use checks apply at request time; coordinate host
mounts and direct raw writes separately. Raw USB I/O and FUSE remain
available. The guest cannot load host kernel modules directly.
`sys usb-mount-help` and `/etc/crow-ai-usb-mounts.md` explain this interface
inside the guest; the login banner and wrapper errors point to that guide.

Crow uses a dedicated launcher in `ai-container-runtime.nix`, rather than the
standard launcher's shared host Nix mounts. Guest UIDs/GIDs 0 through 1048575
map to host IDs 1048576 through 2097151. Reserve that host range for this
container; do not assign it to host accounts or another container. Rootless
Docker uses guest subordinate IDs 100000 through 165535 within that range.
ID-mapped mounts preserve existing on-disk ownership of the root, home, and
scratch files without a recursive chown. Startup requires kernel/filesystem
support for ID-mapped mounts and fails rather than falling back to unmapped
root. Crow's Btrfs storage supports these mounts.

The guest runs its own Nix daemon with a writable store, database, profiles,
and GC roots under host `/var/lib/crow-ai/nix`, persisted on `/persist`.
The running guest has no host Nix store or daemon socket mounted. A temporary
user namespace, with the host store read-only and no daemon socket, copies
the guest system closure before boot. Copies use reflinks where possible,
never hardlinks to host store files. The guest registers its own system
closure and roots it before starting services. The daemon's writable-socket
directory condition now applies to the guest's own state.

Guest builds use Nix's full, unmodified build sandbox (user, mount, PID,
IPC, UTS, and network namespaces plus chroot). Two kernel facts make that
work inside nspawn, where it normally cannot:

- nspawn always overmounts `/proc` files and directories (masked
  `/proc/kcore`, `/proc/keys`, `/proc/kallsyms`, a read-only `/proc/sys`,
  and more). Those mounts are unlocked at the container's own privilege
  level, but the kernel locks every mount when a mount namespace is copied
  into a child user namespace. Nix's sandbox performs such a copy, and the
  kernel then refuses its fresh per-build `/proc` remount with "VFS: Mount
  too revealing" (`mount_too_revealing()` in fs/namespace.c refuses when
  the visible proc has locked overmounts over non-empty files).
- Guest root can unmount the overmounts at any time, so they are not a
  boundary against the ID-remapped container; the uid mapping already
  protects the masked nodes through DAC (`/proc/kcore` is 0400 root:root
  against guest uid 1048576).

`crow-ai-unmask-proc.service` therefore removes every overmount under
`/proc` (deepest first, with a lazy detach for the busy `/proc/sys`)
before `nix-daemon.service` starts. nspawn recreates the overmounts on
every container start, and the service clears them on every guest boot.
A verified sandboxed build sees only its own PID namespace (one process
visible versus dozens in the container). `sandbox-fallback` stays enabled
so that if a future systemd/nspawn change ever makes `/proc` uncleanable
again, builds degrade to unsandboxed with a warning instead of failing;
the nspawn boundary still confines the daemon's `nixbld` builders.

Rootless Docker containers additionally need a sysfs instance at a
superblock root: nspawn presents a user-namespaced container's `/sys` as a
tmpfs with read-only subtree binds, so the kernel's visibility check
denies every fresh sysfs mount in child user namespaces, and runc fails
starting containers ("error mounting sysfs"). A userns container cannot
bootstrap its own first sysfs instance. The launcher therefore prepares an
**empty sysfs seed**: a sysfs instance mounted on the host for a dedicated
throwaway network namespace (it lists only `lo`, disclosing nothing),
bound read-only into the guest at `/run/host/sysfs-seed`. runc mounts each
container's sysfs read-only via the classic `mount(2)` path, which the
read-only seed satisfies; containers then see their own network
namespace's sysfs, not the host's. The seed's network namespace and mount
persist across container restarts and are recreated on host reboot.

The container still shares Crow's kernel, can contact Crow and the LAN, and
can directly modify exposed USB media. User ID remapping and independent
Nix remove important host privilege paths, but kernel vulnerabilities and
explicitly shared resources remain part of the boundary. Other AI containers
retain the shared default of no sudo and their existing Nix setup.

Before the first restart, back up the stopped guest root and any Nix user
profiles needed for recovery. Existing home/application data is retained.
The private store initially contains the guest system closure; packages
installed through old user Nix profiles may need reinstalling. Old host-side
profiles and GC roots are left intact, but are not mounted into the guest.
The first start needs space for the closure and may take longer; its startup
timeout is 30 minutes. Future host rebuilds require restarting the container
to seed and boot the new system; automatic in-place reload is disabled.

After rebuilding, restart `container@crow-ai` (interrupting guest sessions).
The restart replays USB device events into the mirror, so the guest's raw
`/dev/bus/usb` view and libusb access start complete without reconnecting
devices; later hotplug propagates normally. In the guest,
check the expected normal device path, such as `ls -l /dev/sdb1`, and its
read/write permissions. `systemctl status crow-ai-usb-dev-layout` diagnoses
the normal-path sync service. Device names can change after reconnecting. Later hotplug
does not require a rebuild. If a newly loaded driver registers a new device
major, restart the container after connecting it so systemd refreshes its
device allowlist. USB disk drivers are preloaded to avoid this for storage.

After the remapping transition, verify inside the guest:

```sh
sudo -n id
cat /proc/self/uid_map /proc/self/gid_map
sudo systemctl start nix-daemon.service
systemctl status nix-daemon.service
findmnt -T /nix/store
nix build --no-link nixpkgs#hello
systemctl --user status docker
docker run --rm hello-world
```

The maps should show `0 1048576 1048576`; `sudo` should report guest UID 0.
On Crow, `systemctl show container@crow-ai -p ExecStart` should reference
`crow-ai-start`. Check the guest's `/proc/self/mountinfo` for its private Nix
mount and confirm there are no host database, socket, or per-container
profile mounts. Builds and evaluation do not establish runtime isolation;
the first restart must verify the maps, private daemon, Docker, FUSE, and USB
permissions on Crow. The host broker socket starts before the container;
rebuild the host and restart `container@crow-ai` to install both ends. With a
disposable USB filesystem, verify mounting, creating a file (unless read-only),
and unmounting through the commands above. On Crow inspect
`journalctl -u crow-ai-usb-mount.service` if the broker cannot start.
Run `python3 scripts/test-crow-usb-mounts.py` for policy tests and an actual
mount/unmount test using tmpfs in disposable user/mount namespaces, without
physical disks. The kernel test skips if unprivileged namespaces are unavailable.
Runtime regression tests can be run after building with
`python3 scripts/test-crow-container-runtime.py /nix/store/...-crow-ai-start`,
using the `ExecStart` path from `nix eval --raw path:.#nixosConfigurations.crow.config.systemd.services.container@crow-ai.serviceConfig.ExecStart`.
The same pattern applies to
`python3 scripts/test-crow-unmask-proc.py /nix/store/...-crow-ai-unmask-proc`
with the `ExecStart` from
`...systemd.services.crow-ai-unmask-proc.serviceConfig.ExecStart` inside
`containers.crow-ai.config`; it checks that the service's target selection
picks up every /proc overmount, in deepest-first order.

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

The same configuration works before Secure Boot enrollment. The command
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
2. For a fresh format, set `crow.storage.luks.cryptroot.volumeKeyId` to `null` in the
   local input's `hardware-identities.json` so it cannot reuse the previous disk identity.
   Provision the live installer from that inventory using the host hardwareProvisioner
   (without `--root`) to establish its installation disk selector. Build and review the disk script. Running it is the destructive operation:
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
   checkout into `/mnt/persist/nixos-config`. Provision hardware state again with
   `--root /mnt --inventory /LOCAL/INPUT/hardware-identities.json`, then install with
   `nixos-install --no-root-passwd --flake path:.#crow`.
5. Boot with local console access, unlock LUKS, and verify Wi-Fi, SOPS,
   persistent files, swap, and container connectivity. Back up existing firmware
   keys with `sudo sys backup-secure-boot`, then complete the documented manual
   Secure Boot enrollment and cold-boot verification.
6. Obtain `sudo sys root-volume-key-id` and record the value in
   `crow.storage.luks.cryptroot.volumeKeyId` in both the local input and the SOPS-encrypted source; never reuse Warbler's value or a test pin.
   Run `sudo sys hardware-provision --repo "$PWD" --inventory /LOCAL/INPUT/hardware-identities.json`
   and rebuild `.#crow`; the hook automatically generates the initrd SSH host key
   and seals available credentials. No manual SSH key generation is needed.
   Run `sudo sys setup-unlock-tailscale` to provision the separate `crow-unlock`
   identity, then rebuild for boot to include it. Wi-Fi requires the profile
   at `/persist/credstore/wifi`; initial absence defers Wi-Fi, not wired recovery.
7. Cold-boot with console recovery available and verify
   `ssh -t -p 2222 root@crow-unlock` can unlock the disk over Wi-Fi. Retire
   unpinned bootstrap artifacts and their accepted measurements before running
   `sudo sys setup-luks-tpm-unlock`. Verify an unattended cold boot separately.

## Validation

These commands use synthetic fixtures unless given the production input override.
Do not install their outputs or run their Disko scripts on real disks.

From this checkout (the `path:` form includes newly created, untracked files):

```sh
nix eval --impure --json --file scripts/test-crow.nix
python3 scripts/test-secure-unlock-setup.py
nix build --no-link path:.#nixosConfigurations.crow.config.system.build.toplevel
nix build --no-link path:.#nixosConfigurations.crow.config.system.build.diskoScript
nix flake check --no-build path:.
```

The configuration test checks LVM/swap wiring, reset ordering, the absence of a
host AI account, container routing, SOPS ordering, sealed iwd recovery, and
the TPM-gated TrueNAS restic backup wiring.
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

The restic repository password and the TrueNAS REST-server password are
shown once by `sudo sys setup-backup-keys generate` and sealed to Crow's
TPM; they exist nowhere else. Keep both in the password manager alongside
this bundle; without them the TrueNAS backups cannot be restored.

### Whole-volume deduplication

`dedupit.service` starts at boot and runs incremental deduplication hourly.
The native Rust service privately mounts `/dev/mapper/crow-root` with
`subvolid=5`, covering all Btrfs subvolumes, including root, Nix store, home,
persistent data, and container storage. Its index and reports live in
`/var/lib/dedupit` (persisted under `/persist`). Runs use idle I/O priority
and pause when available space falls below 5 GiB.

Use `sudo sys dedupit-stats` for a current sharing estimate and scan activity;
add `--json` for machine-readable output. Normal text/JSON reads bounded,
buffered summaries; `sudo sys dedupit-stats --errors` explicitly streams full
file-error details. Error counts remain complete even though the default preview
contains only ten examples. Read-only matches donate to writable copies regardless of indexing order;
immutable destinations are counted as skips and remain read-only.
`Current sharing estimate` is rebuilt
from verified indexed extent mappings and current hardlink counts, including
sharing created before dedupit. It shows its indexed-file coverage, data amount,
age, and refresh progress. Until indexing catches up, this represents an indexed
subset rather than a complete filesystem inventory. The indented `Coverage`
amount and percentage apply only to the `Physical estimate` above them.

`Dedupit activity history` and `Recorded work` are cumulative operation counters;
repeated work can be counted again. `Dedupe accepted` is not a current total of
space savings. The background inventory refreshes normally every five minutes
and is saved as `/var/lib/dedupit/sharing-inventory.json`. Logs are available
with `sudo journalctl -u dedupit.service`.

Crow uses NOCOW for its hot SQLite database and WAL to reduce random-write
amplification. Directory IDs and filenames replace repeated full file paths;
normal upgrades preserve hashes, pending/completed work, and scan cursors.
For offline compaction, run `sudo systemctl stop dedupit.service`,
`sudo sys dedupit-compact`, then `sudo systemctl start dedupit.service`.
The native compactor refuses a running service and validates the replacement
before an atomic swap. Inline extent records retain a header and payload digest;
candidate chunks share one hash record between reuse and deduplication.
These migrations preserve existing hashes, jobs, and scan progress. Keep enough free space for the replacement database.
The WAL can grow during active snapshots but is limited to 64 MiB when reset;
sharing-estimate verification and sorting release the main snapshot first.

The service and NixOS module come from the dedupit flake, pinned to its
`main` branch on GitHub. Fetching this private input requires GitHub
SSH access when the source is not already cached.
