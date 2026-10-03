# Primary AI environment

`containers.ai` is the primary AI environment, a persistent NixOS system named
`warbler-ai`. The legacy host `cody-ai` account and home remain for recovery;
the host's `codex-ai.service` is disabled. The container's root, home, SSH host
keys, and application state live under `/var/lib/nixos-containers/ai`, covered
by Warbler's encrypted `/var/lib` persistence. Do not destroy this directory
when rebuilding. The host home is not mounted into the container.

## Network and login

The container has a private network namespace and a macvlan on wired `eno1`.
It requests its own LAN DHCP lease with MAC `02:57:41:52:41:49` and hostname
`warbler-ai`. Reserve that MAC on the router for a stable IP. This is a separate
LAN address, not a separate VLAN or a restriction on outbound LAN access.
Warbler's existing interface, DHCP identity, and SSH endpoint are unchanged.
Wi-Fi is not a fallback for this container.

From another LAN machine, connect using the DHCP address or mDNS:

```sh
ssh cody-ai@warbler-ai.local
```

The account accepts the existing public keys from `nixos/ssh-auth.nix`, has no
sudo access, and allows ordinary SSH/SFTP and forwarding within the container.
It has a separate SSH host identity. The shared Home Manager SSH config maps
`warbler-ai` to `cody-ai@warbler-ai.bed.einic.org:22`, overriding old local
aliases for that name. Point the desktop connection at `warbler-ai`. The separate
`warbler-ai-tailscale` alias uses `cody-ai@warbler.little-moth.ts.net:2223` for
clients connected to the tailnet. mDNS clients can also use `warbler-ai.local`.

Through Warbler's Tailscale address, use port **2223** (2222 remains reserved
for initrd SSH):

```sh
ssh -p 2223 cody-ai@warbler.little-moth.ts.net
```

The short name `warbler` can resolve to LAN addresses before its Tailscale
address, causing port 2223 connections to stall. To keep using
`ssh cody-ai@warbler -p 2223`, add this to your SSH client configuration
(on clients that include `~/.ssh/config.d/*`, use a file in that directory):

```sshconfig
Match originalhost warbler exec "test %p = 2223"
  HostName warbler.little-moth.ts.net

Host *
```

This selects the Tailscale hostname only for port 2223; ordinary host SSH
continues to use its existing address selection.

In t3, use that hostname, user `cody-ai`, and SSH port `2223`. This endpoint
presents the container's SSH host key, not Warbler's host key. The socket binds
only to `tailscale0`; port 2223 is not exposed on the LAN. A dedicated private
veth pair (`10.79.0.1/24` on the host, `10.79.0.2/24` in the guest) carries the proxy
traffic without changing the guest's LAN DHCP lease or default route. No
Tailscale subnet route or separate container Tailscale identity is required.

Warbler also advertises **`10.79.0.2/32`** as a Tailscale subnet route. Once
approved in the Tailscale admin console (or by an auto-approver), clients that
accept subnet routes can use `ssh cody-ai@10.79.0.2` on the normal port 22.
Only the container IP is advertised; the rest of `10.79.0.0/24` is not.
Tailscale's default subnet SNAT provides the return path, preserving the
container's LAN default route. The `10.78.0.0/24` range belongs to the Actions
VM scaler and must not be reused for this container.

Macvlan does not allow direct communication between the host and its own child
interface. Administer locally through the container manager instead:

```sh
ssh cody@warbler 'sudo nixos-container run ai -- ip -4 address show mv-eno1'
ssh -t cody@warbler 'sudo nixos-container root-login ai'
```

GitHub HTTPS operations default to this account's own `gh` login through
Nix-managed `/etc/gitconfig`. See [GitHub HTTPS authentication](ai-harnesses.md#github-https-authentication)
for defaults and repository overrides.
The same shared module also applies your Git identity at activation. See
[setup coverage and remaining logins](ai-harnesses.md#setup-coverage-and-remaining-logins)
for the automated setup, login checks, and unattended credential options.

## Services and compatibility

The container runs its own systemd, D-Bus, and SSH server. Its `cody-ai` user
has lingering enabled, so the user manager starts at boot and survives logout.
SSH and agent tasks share the container filesystem and user-manager sockets.
User services inherit the coding tool PATH without requiring a login shell.

The container uses the same [AI user configuration](ai-user-config.nix) as the
host's `cody-ai` account: Cody's tmux config is linked into `~/.tmux.conf`, and
every container activation applies `codex-configure` to the mutable Codex
config, including existing files. See the [Codex defaults](../../config/codex.md)
for the settings and preservation behavior. No separate Home Manager switch is
needed; new tmux servers and Codex sessions pick up the settings.

`/bin/bash`, `/bin/kill`, `/usr/bin/env`, and selected `/usr/bin` command aliases
support conventional scripts. `nix-ld` supports standard Linux dynamic loaders.
This remains NixOS: software that requires apt, arbitrary FHS libraries, a
desktop, GPU access, or privileged installation may need additional packaging.

Codex runs in the foreground as a **user** service. Systemd tracks the actual
app-server process; there is no detached-daemon PID-file watchdog or native
updater. This prevents updater failures from terminating healthy sessions.
The server uses the dedicated `~/.codex/packages/app-server-daemon/current`
package when installed, falling back to the standalone CLI for initial setup.

The `codex-ai-update.timer` checks hourly (with a short randomized delay), updates
both the CLI and daemon packages through the standalone installer, and requests
a reload when the selected server differs from the running executable. Installer
errors leave the server running. Explicit package pins are respected through the
installer's `auto-update-version` selection guard.

Reload sends **SIGHUP** to the app server. Codex stops admitting new turns and
waits for active turns to finish before exiting; systemd then starts the selected
package. Repeated SIGHUP requests do not force termination. Unlike the native
updater's bounded shutdown grace, this service uses `TimeoutStopSec=infinity`.
A stuck turn can therefore defer an update indefinitely. Clients reconnect after
the drain; this is not a connection-preserving hot swap. Explicit force-kills,
container termination, and host shutdown can still interrupt work.

Routine NixOS switches do not restart this unit. New supervisor settings apply
at its next start. Run inside the container, without administrator access:

```sh
systemctl --user status codex-ai
journalctl --user -u codex-ai -n 100 --no-pager
systemctl --user list-timers codex-ai-update
sys update-codex    # Install packages, then request a drain if needed.
sys restart-codex   # Request a graceful drain and restart, without installing.
codex app-server daemon version
codex login --device-auth
codex remote-control pair
```

The `sys` commands return after requesting a drain, which may still be running.
Use systemd and these helpers for lifecycle changes, not native `daemon
bootstrap/restart/update`: the server is systemd-managed rather than pid-managed.
Native socket discovery, `daemon start/version`, proxying, and phone pairing
still use the common socket. Authentication and real phone pairing require the
user's account and are verified separately.

Install Hermes into the container's own home using its upstream installer:

```sh
sys install-hermes --skip-browser --skip-computer-use
hermes setup
hermes gateway setup
hermes gateway install
hermes gateway start
hermes gateway status
```

The helper downloads the [official Hermes installer](https://hermes-agent.nousresearch.com/docs/getting-started/installation)
as the unprivileged user. The existing host installation was copied during the
2026-10-01 migration; this helper is available for fresh installations.
The suggested flags skip browser/desktop components for an initial headless
setup. Model and messaging credentials are configured interactively. Add other
harnesses with their own user units under `~/.config/systemd/user`.

## Migration from the host (2026-10-01)

The container's pre-existing Codex/T3 state stays primary. The host's full home
was copied with Btrfs reflinks to
`~/migration-from-host-20261001/home`, including its independent Codex databases,
sessions, credentials, and T3 state. Those databases were not overlaid onto the
container's live databases. The original `/home/cody-ai` on the host is retained.

Host projects are also available at their original paths under `~/zpl`, while
existing container projects remain under `~/p` (`~/workspaces` points there).
Hermes is installed at `~/.hermes`; its user unit was copied but not enabled,
matching the old host state. Missing user tools, GitHub/SSH configuration, and
Codex skills/rules were copied without overwriting existing container files.
Conflicting settings and caches remain available in the full migration archive.

## Boundaries

The container's `/tmp` is a writable bind mount of `/var/lib/warbler-ai/tmp`
on the host's encrypted SSD. Its host parent is root-only; it is separate from
both the host `/tmp` and the legacy host AI account. It shares the SSD's free
space rather than having a small RAM limit. Files survive container restarts;
the guest's standard tmpfiles policy removes aged entries after 10 days.

Scratch storage inherits `noatime`. On Btrfs, the directory has `chattr +C`,
so new files avoid data copy-on-write, data checksums, and compression. This
favors disposable build scratch over crash durability and integrity; metadata
protection and explicit application sync calls still work normally. No global
filesystem durability settings are changed. Executables are allowed for builds.
Changing this bind mount requires a container restart, ending its running
sessions; save needed files from an existing tmpfs before that restart.

This is a shared-kernel system container, not a VM. It has no host-home,
`/persist`, secrets, or host systemd/D-Bus bind mounts. Standard NixOS containers
share the read-only Nix store and the host Nix daemon; UID 1001 has the same
ordinary untrusted Nix access as the existing host AI account. Builds therefore
run under the host's Nix build policy. Container root is administratively
trusted; do not grant it to agents. All applications under the container AI
UID can access each other's credentials. Outbound networking is unrestricted.

## Build and activation

```sh
nix build .#checks.x86_64-linux.warbler-ai-container --no-link -L
nix build .#nixosConfigurations.warbler.config.system.build.toplevel --no-link
nix run .#warbler-nixos-rebuild-remote -- switch
```

The first two commands build and test without changing running services. The
last activates the entire checked-out host configuration: review other pending
host changes before using it. Warbler disables the old host service while retaining the account and home for
recovery.

Host switches reload the running container and activate its guest configuration
in place. Guest services may still restart when their configuration changes,
but the container itself and unaffected sessions keep running. Changes to the
container boundary, such as macvlans, veths, bind mounts, or nspawn settings,
require an explicit restart after the host switch:

```sh
ssh cody@warbler 'sudo systemctl restart container@ai'
```

The offline two-machine VM test verifies a separate DHCP lease, SSH, filesystem
separation, `/bin/bash`, lingering user systemd, real Codex command execution
with user-service access, and state surviving container restart. It uses the
pinned Codex package as an installer fixture. It does not authenticate to
providers, install Hermes from the internet, prove LAN DHCP on physical hardware,
or establish desktop/phone pairing.
