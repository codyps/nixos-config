# Cargo target cache

The Cargo wrapper creates `target` links into
`${XDG_CACHE_HOME}/cargo-targets`, falling back to
`~/Library/Caches/cargo-targets` on macOS or `~/.cache/cargo-targets` on Linux.
Build commands recreate a missing destination of an existing managed link,
including links using older cache names or relative paths. Commands that do not
use the workspace target, help, and explicit target-directory overrides do not
repair links. `cargo clean` also handles older managed links; a full clean
removes the dangling link, while `--dry-run` preserves it.

## Garbage collection

`cargo gc` previews removal of every direct cache directory. Add `--delete` to
apply the selection. Stop Cargo builds before collection: this command does not
lock against Cargo, and removal can interrupt a build using a selected cache.

```sh
cargo gc --older-than 30                 # preview caches unmodified for 30 days
cargo gc --older-than 30 --delete        # delete those caches
cargo gc --delete                       # delete all target caches
cargo gc --broken-links --root ~/src     # preview dangling target links
cargo gc --broken-links --root ~/src --delete
cargo gc --caches --broken-links --root ~/src --delete
```

The age filter uses the newest modification time anywhere in the cache tree;
this measures modification, not last access. Symlinked directories are not
followed. Cache removal leaves workspace links behind unless `--broken-links`
is also selected. Previewing both shows links that would become dangling.

Repeat `--root` to search multiple project trees. Link cleanup only removes
dangling links named `target` pointing directly inside the selected cache root;
it preserves real target directories and links to other locations. Project
discovery never scans the home directory implicitly. `.git` and target contents
are skipped. To collect an older cache location, pass
`--cache-root ~/path/to/cargo-targets`.

Run regression tests with `python3 scripts/test-cargo-cache.py` with Bash, jq,
and GNU coreutils on PATH (the same dependencies as the Nix wrapper).

## Native Windows

The `scripts/windows` directory contains a native PowerShell implementation.
It uses directory junctions, so creating a cached `target` does not require
Developer Mode or an elevated shell. Its default cache is resolved at runtime
as `$HOME/.cache/cargo-targets`; `XDG_CACHE_HOME` can override the `.cache`
portion. Literal dashes in a workspace path are doubled before drive and path
separators are converted to dashes, matching the Unix wrapper's naming scheme.

Install it from PowerShell with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\setup.ps1
```

The idempotent setup script copies the four runtime files to
`$HOME/.local/lib/cargo-cache` and moves that directory to the front of the
current user's `PATH`. Pass `-InstallDirectory D:\path\to\cargo-cache` to use a
different location, or `-WhatIf` to preview the changes. Open a new terminal
afterward so it receives the updated user environment. `cargo.cmd` then shadows
`cargo.exe` and dispatches `cargo gc` to the bundled collector;
`cargo-gc.cmd` also permits a direct `cargo-gc` invocation. The wrapper resolves
the real `cargo.exe` at invocation time; set
`CARGO_WRAPPER_REAL_CARGO` only when an unusual installation needs an explicit
path.

The Windows `cargo gc` options and safety rules are the same as those above.
Broken-link cleanup recognizes both directory junctions and directory symbolic
links but never traverses reparse points. Stop builds before deleting caches.

For Codex on Windows, add the resolved cache location to the workspace-write
allowlist (TOML accepts forward slashes):

```toml
sandbox_mode = "workspace-write"

[sandbox_workspace_write]
writable_roots = ["~/.cache/cargo-targets"]

[windows]
sandbox = "elevated"
```

The scripts are kept compatible with Windows PowerShell 5.1 and prefer
PowerShell 7 (`pwsh.exe`) when it is installed. On the Windows machine, run
`powershell -ExecutionPolicy Bypass -File scripts/windows/test-cargo-cache.ps1`
to exercise the real Cargo executable and NTFS junction behavior.
