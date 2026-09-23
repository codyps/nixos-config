# Mutable Codex defaults

Home Manager activation seeds `~/.codex/config.toml` if no file exists. Warbler
also seeds the `cody-ai` account during NixOS activation, on both the host and
the AI container. The resulting file is a user-owned regular file (mode 0600),
not a Nix store symlink. Later activations leave existing files untouched.

To apply the current defaults to an existing config, close Codex instances
using that config, then run as its owner:

```sh
codex-configure
```

The command is installed with these configurations and is also available with
`nix run .#codex-configure`. It honors `CODEX_HOME`; `--config /absolute/path`
selects a different file. `--if-missing` performs the activation's seed-only
operation.

It sets top-level `sandbox_mode = "workspace-write"` and
`sandbox_workspace_write.network_access = true`. It appends missing cache
paths to `sandbox_workspace_write.writable_roots`, retaining existing entries,
unrelated settings, and TOML comments. Repeating the command adds no duplicates.
Malformed configs and symlinks are rejected rather than replaced. Avoid running
the explicit update while Codex is editing the file; Codex does not share a lock
with this command.

The cache subdirectories are `bazel`, `bazelisk`, `cargo-targets`, `mbx`, `nix`,
and `uv`. macOS uses `~/Library/Caches`; Linux uses `$XDG_CACHE_HOME`, falling
back to `~/.cache`. Home Manager activation uses its configured `xdg.cacheHome`
on Linux; the Warbler service accounts use `~/.cache`. `--cache-home` overrides
the base directory. Cache directories are created when seeding or updating.
These permissions do not redirect tools' own cache settings.

The defaults apply to new Codex sessions, subject to higher-precedence project,
profile, and command-line settings. Activation does not restart Codex.
