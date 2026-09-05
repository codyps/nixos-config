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
