# GitHub Actions runners

Warbler runs GARM 0.2.1 with the Incus provider 0.1.5. Each runner is a
disposable KVM VM. GitHub scale sets allow zero idle VMs without a public webhook.
The Incus `garm` project is configured for two runner VMs, with each of the two
repository scale sets limited to one concurrent runner. Each VM has 4 vCPUs,
8 GiB RAM and a 40 GiB disk. Excess work queues; these are capacity limits,
not reservations.

Incus uses a directory pool on the existing Btrfs filesystem under `/var/lib/incus`; it does not
repartition disks. `/var/lib` already persists on Warbler's encrypted `/persist`.
The host's existing AI container is independent of this project.

## Administration

After activating the configuration:

```sh
sudo sys garm bootstrap
sudo sys garm provider list
sudo sys garm controller show
```

`bootstrap` creates a local administrator with a generated password, saved in
`/var/lib/garm/admin-password` with mode 0600. `sudo sys garm` authenticates locally
and delegates to the upstream CLI without putting the password in process arguments.
It maintains the `warbler` CLI profile, preserving other named profiles.
The upstream `garm-cli` is also installed for interactive use.

The admin API/UI listens only on `127.0.0.1:9997`. To access it from a workstation:

```sh
ssh -L 9997:127.0.0.1:9997 cody@warbler
```

Open `http://127.0.0.1:9997`, username `admin`. Retrieve the password privately on
the host; do not paste it into chat or commit it. Local keys in `keys.json` encrypt
GitHub credentials in the database. Back up that file together with the SQLite
database using a consistent SQLite backup, and protect the backup as secret data.
Never delete/regenerate the database key while retaining the database.

## GitHub App and repositories

The private App `codyps-warbler-garm` is installed only on `codyps/zpl` and
`codyps/zpl-comparison`:

- App ID: `5099875`; installation ID: `165554289`.
- GARM credential: `codyps-app`; scale set: `warbler-linux` (ID `1`).
- GARM repository ID: `e73b49df-0546-4662-965e-e75ade5ca8a1`.
- `zpl-comparison` repository ID: `a6b37378-d884-40d1-99d9-eeb2871f6076`;
  its separate `warbler-linux` scale set has GARM ID `2`. Both scale sets use
  min 0/max 1 to avoid racing each other against the shared project quota.
  Both repositories share the Incus project's two-VM total limit.
- The App key is SOPS-encrypted in `garm-app-key.enc.json` and decrypted to
  root-only `/run/secrets/garm-app-key`. GARM also encrypts its imported copy in
  its database. Key rotation requires updating both copies.

App configuration:

- Homepage: `https://github.com/cloudbase/garm`.
- Disable the webhook; do not configure OAuth callbacks.
- Repository permissions: Administration read/write, Metadata read-only.
- Install only on the two selected repositories above.
- Generate an App private key. Keep the PEM outside the checkout and Nix store.
  If persisted in this repository, encrypt it with SOPS for Warbler first.

For recovery on a new controller, import the key from its root-only runtime file
(these records already exist on Warbler):

```sh
sudo sys garm github credentials add --name codyps-app --endpoint github.com \
  --description "Warbler runners for codyps/zpl" \
  --auth-type app --app-id 5099875 --app-installation-id 165554289 \
  --private-key-path /run/secrets/garm-app-key
sudo sys garm repo add --owner codyps --name zpl --credentials codyps-app \
  --random-webhook-secret
sudo sys garm repo add --owner codyps --name zpl-comparison --credentials codyps-app \
  --random-webhook-secret
sudo sys garm repo list
```

Create a scale set for each repository ID returned above:

```sh
sudo sys garm scaleset add --repo REPOSITORY_ID --provider-name incus \
  --image images:ubuntu/24.04/cloud --flavor runner --name warbler-linux \
  --min-idle-runners 0 --max-runners 1 --enabled
sudo sys garm scaleset list
```

Select this scale set with `runs-on: warbler-linux` in a workflow. Personal-account
repositories need separate GARM repository registrations and scale sets; GitHub
App installations do not create an account-wide runner group.

The base cloud image is not a GitHub-hosted runner image: toolchains and Docker
must be explicitly installed or baked into a custom Incus image when needed.
Pin a tested image fingerprint before relying on reproducible image contents.

## Isolation and checks

`garm0` is a private NAT bridge. Guests can reach public IPv4 destinations, DNS,
DHCP, the authenticated GARM metadata/callback/agent endpoints, and the build
cache HTTPS endpoint described below. nftables drops
guest traffic to private, link-local and tailnet ranges and all other host ports.
Incus NIC filtering and port isolation block spoofing and direct guest-to-guest
traffic. Guests have no host filesystem or daemon socket mounts. The controller
is trusted: its Incus admin socket access is equivalent to host administration.

The guest proxy on `10.77.0.1:9998` exposes only runner endpoints; `/api/v1/first-run`,
the admin API and UI return 404 there. Public GitHub jobs and private deployment
secrets should not share a trust policy merely because guests are disposable.

Live validation on 2026-09-27 passed creation from zero, two simultaneous jobs,
private-repository checkout, and a replacement VM with a different hostname and
no sentinel file from previous jobs. All VMs were automatically deleted afterward.
The initial smoke workflow is on `codex/garm-runner-validation`:
https://github.com/codyps/zpl/actions/runs/36346328033

The production workflows now use `warbler-linux` on both repositories' default
branches. ZPL PRs #14 and #15 and zpl-comparison PR #3 are merged. Post-merge
ZPL CI and release preparation passed, as did comparison report generation and
publication. ZPL's Pages build passed, but deployment returns GitHub's Pages-not-
enabled 404 and requires separate repository publishing configuration.

A second run cancelled during VM startup also returned the project to zero VMs:
https://github.com/codyps/zpl/actions/runs/36346550667

The NixOS system was built and activated with `switch`, including the persistent
boot generation. A reboot has not been performed as part of validation.

Guest probes confirmed GitHub HTTPS works while host SSH/admin API, LAN and
tailnet connections are blocked. The guest proxy returns 404 for admin routes
and 401 for unauthenticated metadata requests.

After a job completes, `sudo incus list --project garm` should return to empty.
Inspect controller and proxy logs with `journalctl -u garm -u nginx`.

Upstream references:

- https://github.com/cloudbase/garm/blob/v0.2.1/doc/scale-sets.md
- https://github.com/cloudbase/garm/blob/v0.2.1/doc/credentials.md
- https://github.com/cloudbase/garm-provider-incus/tree/v0.1.5

## Persistent build caches

`garm-cache.nix` provides an 80 GiB Bazel action cache for zpl-comparison and a
separate 20 GiB sccache backend for zpl. Both use bazel-remote's disk storage and
LRU eviction. `/var/lib/garm-bazel-cache` and `/var/lib/garm-rust-cache` persist
across VM deletion and reboot (DynamicUser resolves these through
`/var/lib/private`). There is no cloud backend or guest filesystem mount.

Use `sudo sys garm-cache-status` for size/file counts and
`sudo sys garm-cache-check` for live TLS, round-trip and authorization tests.
Logs are in `journalctl -u garm-bazel-cache -u garm-rust-cache -u nginx`.

Nginx exposes cache objects on `https://10.77.0.1:9443`, which is permitted only
through the runner bridge firewall. Other host ports remain blocked. Backend
listeners and status endpoints remain on loopback. Each repository has separate
storage and credentials: URL prefixes alone do not isolate Bazel CAS data.

The Rust backend accepts opaque sccache values through its HTTP action-cache
API, with protobuf validation disabled only for that separate backend. Nginx
maps sccache's sharded keys to flat action-cache keys. Static WebDAV collection
metadata lets OpenDAL discover virtual parent directories without creating host
filesystem directories; only those empty metadata responses are unauthenticated.
Actual object reads and writes always require credentials.

`garm-cache-auth.service` generates random read/write credentials and a private
TLS CA under `/var/lib/garm-cache-auth`. ZPL credentials live in its `zpl/`
subdirectory; comparison credentials live at the top level. Raw credentials and
private keys never enter Git or the Nix store. Each repository has its own
`WARBLER_CACHE_READ` secret containing `reader:PASSWORD`. Its
`WARBLER_CACHE_WRITE` secret contains `writer:PASSWORD` exclusively in GitHub
environment `warbler-cache-main`, whose selected deployment branch policy allows
only the branch `main`, not tags or PR merge refs. Do not move write secrets to
repository scope or loosen that policy. Other builds use `warbler-cache-read`;
forks without secrets run uncached. Nginx rejects reader writes regardless of
client flags.

Both repositories pin the public CA at `.github/warbler-cache.crt`. Bazel uses a
scoped credential helper; sccache receives credentials through masked environment
variables. Passwords are absent from command arguments and bazelrc logs. ZPL's
Clippy/test jobs disable incremental compilation as required by sccache and
publish cache statistics; linking and unsupported calls still run normally.

The CA expires after ten years. A daily `garm-cache-renew` timer renews the
server leaf for 90 days when fewer than 30 days remain, then reloads nginx.
Inspect dates with `openssl x509 -in FILE -noout -enddate` (`server.crt` is the
CA; `tls.crt` is the leaf). CA rotation requires updating both repositories'
public CA file. Cache preflight failures retry three times and fall back to
uncached builds rather than blocking compilation; authorization boundary failures
(reader unexpectedly able to write) remain fatal.
Credential rotation requires synchronizing the corresponding GitHub secret.
Back up the auth directory as secrets, or regenerate and resynchronize; cached
build outputs are disposable and need not be backed up.

Bazelisk and repository-download archives still use GitHub caching. Cargo/npm
downloads and a prebuilt tool image are separate from these compiler/action
caches; this does not make every Actions cache host-local.
