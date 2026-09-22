# Alternate AI container

`containers.ai` is a persistent NixOS system named `warbler-ai`, separate from
Warbler's existing `cody-ai` account and `codex-ai.service`. Neither the host
home nor its credentials are copied or mounted into the container. Its root,
home, SSH host keys, and application state live under
`/var/lib/nixos-containers/ai`, covered by Warbler's encrypted `/var/lib`
persistence. Do not destroy this directory when rebuilding.

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
It has a separate SSH host identity. A client alias can use `Host warbler-ai`,
`HostName warbler-ai.local`, and `User cody-ai`; point the desktop connection at
this alias to use the alternate environment.

Macvlan does not allow direct communication between the host and its own child
interface. Administer locally through the container manager instead:

```sh
ssh cody@warbler 'sudo nixos-container run ai -- ip -4 address show mv-eno1'
ssh -t cody@warbler 'sudo nixos-container root-login ai'
```

## Services and compatibility

The container runs its own systemd, D-Bus, and SSH server. Its `cody-ai` user
has lingering enabled, so the user manager starts at boot and survives logout.
SSH and agent tasks share the container filesystem and user-manager sockets.
User services inherit the coding tool PATH without requiring a login shell.

`/bin/bash`, `/bin/kill`, `/usr/bin/env`, and selected `/usr/bin` command aliases
support conventional scripts. `nix-ld` supports standard Linux dynamic loaders.
This remains NixOS: software that requires apt, arbitrary FHS libraries, a
desktop, GPU access, or privileged installation may need additional packaging.

Codex uses the existing self-managed standalone installer/supervisor, now as a
**user** service. Its packages, login, workspaces, and history are independent
of the host account. Run inside the container:

```sh
systemctl --user status codex-ai
journalctl --user -u codex-ai -n 100 --no-pager
codex login --device-auth
systemctl --user restart codex-ai
codex remote-control pair
```

Authentication and real phone pairing require the user's account and must be
verified separately. Native daemon discovery/proxy commands work in the same
PID namespace as the managed daemon; there is no custom production adapter.

Install Hermes into the container's own home using its upstream installer:

```sh
install-hermes --skip-browser --skip-computer-use
hermes setup
hermes gateway setup
hermes gateway install
hermes gateway start
hermes gateway status
```

The helper downloads the [official Hermes installer](https://hermes-agent.nousresearch.com/docs/getting-started/installation)
as the unprivileged user; it does not copy the host's installation or tokens.
The suggested flags skip browser/desktop components for an initial headless
setup. Model and messaging credentials are configured interactively. Add other
harnesses with their own user units under `~/.config/systemd/user`.

## Boundaries

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
host changes before using it. The alternate container module itself does not
change the existing host AI account or service.

The offline two-machine VM test verifies a separate DHCP lease, SSH, filesystem
separation, `/bin/bash`, lingering user systemd, real Codex command execution
with user-service access, and state surviving container restart. It uses the
pinned Codex package as an installer fixture. It does not authenticate to
providers, install Hermes from the internet, prove LAN DHCP on physical hardware,
or establish desktop/phone pairing.
