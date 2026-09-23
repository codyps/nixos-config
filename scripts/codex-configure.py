"""Seed or update a mutable Codex config, preserving unrelated TOML content."""

import argparse
import os
from pathlib import Path
import sys
import tempfile

import tomlkit


CACHES = ("bazel", "bazelisk", "cargo-targets", "mbx", "nix", "uv")


def configure(path, cache_home, *, if_missing=False):
    # Even a dangling symlink counts as an existing config during activation.
    if if_missing and os.path.lexists(path):
        return False
    if path.is_symlink():
        raise ValueError(f"{path} is a symlink; replace it with a mutable file first")
    original = path.read_bytes() if path.exists() else None
    document = tomlkit.parse(original.decode()) if original is not None else tomlkit.document()
    if "sandbox_workspace_write" not in document:
        document["sandbox_workspace_write"] = tomlkit.table()
    sandbox = document["sandbox_workspace_write"]
    if not isinstance(sandbox, (tomlkit.items.Table, tomlkit.items.InlineTable)):
        raise ValueError("sandbox_workspace_write must be a TOML table")
    if "writable_roots" not in sandbox:
        sandbox["writable_roots"] = tomlkit.array().multiline(True)
    roots = sandbox["writable_roots"]
    if not isinstance(roots, tomlkit.items.Array) or not all(isinstance(root, str) for root in roots):
        raise ValueError("sandbox_workspace_write.writable_roots must be an array of strings")
    document["sandbox_mode"] = "workspace-write"
    sandbox["network_access"] = True
    for cache in CACHES:
        root = str(cache_home / cache)
        if root not in roots:
            roots.append(root)
    updated = tomlkit.dumps(document).encode()
    for cache in CACHES:
        (cache_home / cache).mkdir(parents=True, exist_ok=True)
    if updated == original:
        return False
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Publish a complete, private regular file. A seed must never clobber a
    # config that appeared after our initial existence check.
    fd, temporary = tempfile.mkstemp(prefix=".config-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(updated)
            stream.flush()
            os.fsync(stream.fileno())
        if original is None:
            try:
                os.link(temporary, path)
            except FileExistsError:
                if if_missing:
                    return False
                raise ValueError("Config appeared during update; retry with Codex stopped")
        else:
            # Codex does not share a lock with this utility. Detect intervening
            # changes, but callers should stop Codex before explicit updates.
            if path.is_symlink() or path.read_bytes() != original:
                raise ValueError("Config changed during update; retry with Codex stopped")
            os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return True


def main():
    parser = argparse.ArgumentParser(prog="codex-configure", description=__doc__)
    parser.add_argument("--if-missing", action="store_true", help="Seed only; never edit an existing file")
    parser.add_argument("--config", type=Path, help="Default: $CODEX_HOME/config.toml or ~/.codex/config.toml")
    parser.add_argument("--cache-home", type=Path, help="Override the platform's cache directory")
    args = parser.parse_args()
    path = args.config or Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "config.toml"
    cache_home = args.cache_home or (
        Path.home() / "Library/Caches" if sys.platform == "darwin"
        else Path(os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache"))
    )
    if not path.is_absolute() or not cache_home.is_absolute():
        parser.error("Config and cache directories must be absolute paths")
    try:
        changed = configure(path, cache_home, if_missing=args.if_missing)
    except (OSError, ValueError, tomlkit.exceptions.ParseError) as error:
        parser.exit(1, f"codex-configure: {error}\n")
    print(f"{'Updated' if changed else 'Unchanged'} {path}")


if __name__ == "__main__":
    main()
