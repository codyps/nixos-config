# AI harness account

Warbler defines `cody-ai` for Cody's AI tools, independently of the administrative
`cody` account. Its persistent home is `/home/cody-ai`; put repositories under
`/home/cody-ai/workspaces`. Existing administrator SSH public keys can log in;
no private keys, Git credentials, or Codex login tokens are copied from Cody.

`codex-ai.service` starts at boot, restarts on failure, and runs OpenAI's mutable
standalone Codex install under this account. On first start it downloads and runs
`https://chatgpt.com/codex/install.sh` as `cody-ai`. It then runs
`codex app-server daemon bootstrap --remote-control`, enabling Codex's own
updater. The supervisor checks the daemon every 30 seconds and restarts the unit
if the updater exits. Both detached children stay inside the systemd sandbox.
The managed package tree is `~/.codex/packages/standalone`; updates survive
reboots and are independent of `flake.lock`. First installation needs internet
access; subsequent starts use the installed copy while Codex checks for updates.

It exposes a private Unix socket, and makes an outbound authenticated remote-control connection for phone
access. It opens no additional firewall ports. The SSH-facing native `codex app-server proxy`
command connects to this same process, so the desktop and phone use the same
account, history, workspaces, and service restrictions.

## Activate and authenticate

After reviewing/building the configuration, deploy with the existing remote
rebuild wrapper (`nix run .#warbler-nixos-rebuild-remote -- switch`). That command
activates the configuration; a build alone does not create the user or service.

Authenticate the separate account using your ChatGPT login:

```sh
ssh -t cody-ai@warbler 'codex login --device-auth'
```

Complete the device login in your browser. Use the ChatGPT account/workspace you
use on your phone. Remote control requires ChatGPT authentication; an API key
alone is insufficient. Credentials remain in this account's private `.codex`
directory on encrypted persistent storage. Do not copy your administrative
account's whole home or SSH agent into this account.

Then refresh the server as the administrator and request a pairing code:

```sh
ssh cody@warbler 'sudo systemctl restart codex-ai'
ssh -t cody-ai@warbler 'codex remote-control pair'
```

Use the returned short-lived code in the phone app's remote-host pairing flow.
Keep pairing output private. The host identifies itself as `warbler` and remains
available while Warbler is awake and online; your laptop need not stay connected.
Pairing requires the remote-control feature to be available for your account.

The inspected Nixpkgs Codex 0.154.0 source implements
`app-server --remote-control` and `remote-control pair` on Linux. These are experimental CLI capabilities. The
[public remote documentation](https://learn.chatgpt.com/docs/remote-connections)
currently describes desktop-host mobile setup, so successful Linux pairing and
a real phone task must be verified after activation and login. The VM test does
not authenticate to OpenAI or claim phone connectivity.

## Desktop SSH connection

Add an explicit alias to the client machine's `~/.ssh/config`:

```sshconfig
Host warbler-ai
  HostName warbler
  User cody-ai
  IdentityFile ~/.ssh/id_ed25519
  ForwardAgent no
```

In the desktop app's Settings > Connections, add/enable `warbler-ai` and select a
repository under `/home/cody-ai/workspaces`. The wrapper supports native
`app-server proxy` and daemon start/version discovery. The custom JSON-lines
stdio adapter is **disabled by default**. Plain `codex app-server` launches are
rejected rather than starting a process outside the service sandbox.

For a client that requires the compatibility adapter, explicitly set:

```nix
services.codex-ai.stdioForwarder.enable = true;
```

This opt-in adds the Python WebSocket bridge. Systemd owns the outer
lifecycle and Codex owns package updates;
SSH daemon bootstrap/update/restart are deliberately rejected so they cannot
start children outside the service sandbox. Restart the service to re-bootstrap
its managed daemon and updater. Unsupported launch arguments fail explicitly
instead of spawning an unconfined server. A future desktop protocol change may require updating this
adapter if Codex changes its CLI contract.

## Access boundaries and other harnesses

The account has a locked password, no supplementary groups, no sudo grant,
no polkit authorization, and no SSH forwarding. It has ordinary, untrusted access
to the host Nix daemon for builds, development shells, and user profiles.
Cody's home and the AI home are mode 0700. SSH shell sessions have ordinary Unix
account permissions; systemd's extra restrictions apply to the managed service
and its descendants, not to arbitrary programs launched directly over SSH.

The managed service additionally has no capabilities or privilege escalation,
a read-only system filesystem, private temporary files and devices, hidden other
homes, and inaccessible `/persist`, host secrets, user-manager sockets, system
D-Bus. The Nix daemon socket is accessible; daemon builds run outside this
service sandbox, under Nix's own build policy. Its writable persistent area is its own home.
It has no service-specific CPU, memory, or task limits (`TasksMax=infinity`).
User namespaces remain enabled for Codex's own sandbox.

Network egress is allowed for OpenAI, Git, and package downloads, including access
to reachable LAN services. This is process/account isolation on a shared kernel,
not a VM or a network isolation boundary. Do not grant this account privileged
groups, forward Cody's SSH agent, or supply infrastructure administrator tokens.
All harnesses under this UID can access each other's files and credentials.

For another harness, add its package and a separate root-managed systemd service
in `ai-harnesses.nix`, reusing the service's confinement settings and this user.
Use a separate private state directory in the home and separate credentials.
Install tools declaratively or into this account's home. Use another UID if
harnesses must be isolated from one another.

## Coding tools

SSH Bash sessions and the managed service share Git, gh, rustup, mbx, Node.js/npm,
Bun, uv, pnpm, Vite+ (`vp`), Python, ripgrep, and jq. The account module owns this environment directly,
so service processes receive it without depending on Home Manager login hooks.
Run `rustup default stable` once to select/download a Rust toolchain.

`npm install -g` installs under `~/.npm-global`; ordinary `npm install` uses the
project directory. Python automatically creates a writable default virtual
environment at `~/.local/share/python-default`, so `pip install` and
`python -m pip install` work without modifying the Nix store. Project-specific
virtual environments (`python -m venv .venv; source .venv/bin/activate`) also work.

PATH includes the default Python environment, `~/.local/bin`, `~/.cargo/bin`,
`~/.npm-global/bin`, `~/.bun/bin`, pnpm/Yarn and Vite+ user bins, `~/go/bin`, `~/.deno/bin`,
`~/.dotnet/tools`, `~/.gem/bin`, and both Nix user profile locations. Language
paths do not themselves install additional language runtimes. mbx is available
as a command; automatic Cargo wrapping is not enabled.

Vite+'s global CLI is pinned to the upstream 0.3.3 GNU/Linux release, with its
archive hash checked by Nix and its ELF loader patched for NixOS. First use
bootstraps its JavaScript toolchain into the user's home and needs internet
access. `nix-ld` supports the upstream Node binaries downloaded by this setup.
The Nix bootstrap package is version-pinned; Vite+ owns its subsequent user-local
installation and updates. The offline VM test checks executable startup and
PATH availability, not those first-use downloads. See the
[upstream global CLI documentation](https://viteplus.dev/guide/global-cli).

## Operation and checks

Run administrative commands as `cody`, not `cody-ai`:

```sh
sudo systemctl status codex-ai
sudo journalctl -u codex-ai -n 100 --no-pager
sudo systemctl restart codex-ai
```

After login/pairing, run a small phone task in the workspace and verify it runs
as `cody-ai`, can write there, and cannot read `/home/cody` or `/persist`. Reboot
when convenient and verify the phone can reconnect without an SSH session.

```sh
nix build .#checks.x86_64-linux.warbler-ai-harnesses --no-link -L
nix build .#nixosConfigurations.warbler.config.system.build.toplevel --no-link
```

The credential-free VM test seeds the standalone directory with Nixpkgs Codex
0.154.0 as an offline fixture, then exercises the real managed bootstrap,
updater process, SSH transport/RPC, forwarding denial, and command execution with Codex's inner sandbox disabled to test the outer service boundary,
no-sudo restrictions, allowed Nix access, coding-tool discovery, Python environments, private temporary files, automatic daemon recovery, and state
across service restart.

It does not download the latest installer release or verify an authenticated
phone session. Production uses the upstream managed release, not this fixture.
The installer and future upstream updates run with this account's access; this
is intentionally a self-updating application rather than an immutable Nix package.
