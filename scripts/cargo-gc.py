#!/usr/bin/env python3
"""Collect Cargo target caches; workspace discovery is explicitly scoped."""

import argparse
import os
from pathlib import Path
import shutil
import sys
import time


def newest_mtime(directory):
    newest = directory.stat().st_mtime
    for parent, directories, files in os.walk(directory, followlinks=False):
        for name in directories + files:
            newest = max(newest, (Path(parent) / name).lstat().st_mtime)
    return newest


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["gc"]:  # Cargo passes the subcommand name to cargo-gc.
        argv.pop(0)
    parser = argparse.ArgumentParser(
        description="Preview removal of Cargo target caches. Stop builds before using --delete.",
        epilog="Examples: cargo gc --older-than 30; cargo gc --delete; "
        "cargo gc --broken-links --root ~/src --delete; "
        "cargo gc --caches --broken-links --root ~/src --delete",
    )
    parser.add_argument("--delete", action="store_true", help="perform the displayed removals")
    parser.add_argument("--dry-run", action="store_true", help="preview only (the default)")
    parser.add_argument("--caches", action="store_true", help="select cache directories (default unless --broken-links)")
    parser.add_argument("--older-than", type=float, metavar="DAYS", help="only caches with no file/directory modification in DAYS")
    parser.add_argument("--broken-links", action="store_true", help="remove dangling target links into the selected cache root")
    parser.add_argument("--root", action="append", default=[], metavar="PATH", help="project tree to search for target links; repeatable; symlink directories are not followed")
    parser.add_argument("--cache-root", help="override the cache directory; its basename must be cargo-targets")
    args = parser.parse_args(argv)
    if args.delete and args.dry_run:
        parser.error("--delete and --dry-run are mutually exclusive")
    if args.older_than is not None and (args.older_than < 0 or not args.older_than < float("inf")):
        parser.error("--older-than must be a finite nonnegative number")
    if args.broken_links and not args.root:
        parser.error("--broken-links requires at least one --root")
    if args.root and not args.broken_links:
        parser.error("--root requires --broken-links")
    if args.older_than is not None and args.broken_links and not args.caches:
        parser.error("--older-than filters caches; add --caches")

    default = "Library/Caches" if sys.platform == "darwin" else ".cache"
    cache_home = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / default)
    cache_root = Path(args.cache_root).expanduser() if args.cache_root else cache_home / "cargo-targets"
    if cache_root.name != "cargo-targets" or cache_root.is_symlink():
        parser.error("cache root must be a directory named cargo-targets, not a symlink")
    cache_root = cache_root.resolve()
    roots = [Path(root).expanduser().resolve(strict=True) for root in args.root]
    if any(not root.is_dir() for root in roots):
        parser.error("every --root must be a directory")
    cutoff = time.time() - (args.older_than or 0) * 86400
    selected = set()
    if args.caches or not args.broken_links:
        if cache_root.exists():
            for entry in sorted(cache_root.iterdir()):
                if entry.is_symlink() or not entry.is_dir():
                    continue
                if args.older_than is None or newest_mtime(entry) < cutoff:
                    selected.add(entry)

    verb = "remove" if args.delete else "would remove"
    for entry in sorted(selected):
        print(f"{verb} cache: {entry}", flush=True)
        if args.delete:
            if entry.is_symlink() or entry.resolve().parent != cache_root:
                raise RuntimeError(f"cache path changed during collection: {entry}")
            shutil.rmtree(entry)

    seen = set()
    if args.broken_links:
        def walk_error(error):
            raise error

        for root in roots:
            for parent, directories, files in os.walk(root, followlinks=False, onerror=walk_error):
                parent = Path(parent)
                directories[:] = [name for name in directories if name not in (".git", "target") and (parent / name).resolve() != cache_root]
                link = parent / "target"
                if link in seen or not link.is_symlink():
                    continue
                seen.add(link)
                destination = link.resolve()
                if destination.parent != cache_root:
                    continue
                if link.exists() and destination not in selected:
                    continue
                print(f"{verb} link: {link} -> {destination}", flush=True)
                if args.delete and link.is_symlink() and not link.exists() and link.resolve() == destination:
                    link.unlink()
    if not args.delete:
        print("Preview only. Use --delete to apply.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        print(f"cargo gc: {error}", file=sys.stderr)
        sys.exit(1)
