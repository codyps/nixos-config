# Mutable Codex defaults

On Crow and Warbler, the `cody` account's `codex-remote-control.timer`
enables remote control on an existing app-server every minute, including
servers started directly by desktop or SSH clients. It starts with the user
manager at boot and skips checks until the socket exists. It does not launch,
replace, or restart the app-server. Run `sys enable-codex-remote-control` as
`cody` for an immediate check, then `codex remote-control pair` to pair a phone.
Native `codex remote-control start` refuses directly launched servers with
“app server is running but is not managed by codex app-server daemon”; the
helper enables the running server through RPC instead.

Crow AI and Warbler AI already start their systemd-owned app-servers with
`--remote-control` and restore it every minute with
`codex-ai-remote-control.timer`. These timers restore remote control after
authentication changes; login is still required. Stop the appropriate timer
before deliberately disabling remote control. Inspect failures with
`systemctl --user status codex-remote-control` on a host, or
`systemctl --user status codex-ai-remote-control` inside an AI container.

Home Manager activation seeds `~/.codex/config.toml` if no file exists and leaves
existing files untouched. Warbler's `cody-ai` accounts, on both the host and the
AI container, apply the current defaults on every NixOS activation, including
to existing configs. They opt into `programs.codex-config.updateExisting`; other
users of the NixOS module retain seed-only behavior by default. The resulting
file is a user-owned regular file (mode 0600), not a Nix store symlink. Unrelated
settings, comments, and additional writable roots are preserved.

To apply the current defaults to an existing config, close Codex instances
using that config, then run as its owner:

```sh
sys configure-codex
```

The command is installed with these configurations (the `codex-configure` helper
is retained for scripts) and is also available with `nix run .#codex-configure`.
It honors `CODEX_HOME`; `--config /absolute/path`
selects a different file. `--if-missing` performs the seed-only
operation.

It sets top-level `sandbox_mode = "workspace-write"` and
`sandbox_workspace_write.network_access = true`. It defaults to “Approve for me”
by adding `approval_policy = "on-request"` and
`approvals_reviewer = "auto_review"` only when each key is absent; explicit
approval policies and reviewers are preserved. It appends missing cache
paths to `sandbox_workspace_write.writable_roots`, retaining existing entries,
unrelated settings, and TOML comments. Repeating the command adds no duplicates.
Malformed configs and symlinks are rejected rather than replaced. Avoid running
the explicit update while Codex is editing the file; Codex does not share a lock
with this command.

The cache subdirectories are `bazel`, `bazelisk`, `gh`, `mbx`, `nix`,
and `uv`. macOS uses `~/Library/Caches`; Linux uses `$XDG_CACHE_HOME`, falling
back to `~/.cache`. Home Manager activation uses its configured `xdg.cacheHome`
on Linux; the Warbler service accounts use `~/.cache`. `--cache-home` overrides
the base directory. Cache directories are created when seeding or updating.
These permissions do not redirect tools' own cache settings.

The defaults apply to new Codex sessions, subject to higher-precedence project,
profile, and command-line settings. Activation does not restart Codex.
