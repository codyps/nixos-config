# Tracked package updates

`nixpkgs/tracked-packages.json` lists packages whose upstream version this
repository intentionally follows more closely than the nixpkgs pin. The
scheduled **nix flake update** workflow runs
`scripts/update-tracked-packages.py` after `nix flake update` and commits the
result with the lockfile and Caddy hashes.

## Update flow

1. On `x86_64-linux`, the updater runs `nix-update --flake` for every manifest
   entry. Entries with a `hashFile` use `--src-only`; their fixed-output hashes
   are maintained separately below. `nix-update` selects the newest stable tag
   from the package's `src` URL and rewrites the version and source hash.
2. The Linux job discovers the requested system's fixed-output hash by
   building the subpackage with a deliberately fake `outputHash` and accepting
   only the resulting hash mismatch. It records the hash in `hashFile` and
   rebuilds the subpackage with the real hash to verify it.
3. If `nixpkgs/opencode.nix` or `nixpkgs/opencode-hashes.json` changed, the
   workflow repeats the opencode hash phase on `macos-15` (`aarch64-darwin`) and
   then `macos-15-intel` (`x86_64-darwin`), committing each result. The last job
   records the completed version in the hash file. Only packages with a
   `hashFile` need this phase.
4. The cache workflow runs against the final commit, so CI builds the updated
   package for every platform.

If one package fails, the updater restores every file for that package and
continues with the remaining entries. The workflow reports a warning, still
commits successful updates, and still runs the Darwin hash jobs for them. A bad
upstream release therefore cannot leave a half-updated package or block the
daily flake update.

A stale `version` field in a hash file makes the next scheduled run repeat the
Darwin hash phase even when the Linux hash did not change. That retries a
previous platform failure instead of leaving Darwin hashes behind.

## Current packages

| Attribute | Expression | Notes |
|---|---|---|
| `dagger` | `nixpkgs/overlays/pkgs/dagger/package.nix` | Go vendor hash via `nix-update` |
| `ethdo` | `nixpkgs/overlays/pkgs/ethdo.nix` | Go vendor hash via `nix-update` |
| `ethereal` | `nixpkgs/overlays/pkgs/ethereal.nix` | Go vendor hash via `nix-update` |
| `mbx` | `nixpkgs/overlays/pkgs/mbx.nix` | Rust cargo hash via `nix-update` |
| `opencode` | `nixpkgs/opencode.nix` | Platform-specific `node_modules` hashes below |
| `s2` | `nixpkgs/overlays/pkgs/s2.nix` | Source only; no vendor hash |

Only `opencode` needs the per-platform hash flow. The other packages use
hashes that `nix-update` maintains in their expressions, so the Linux job is
sufficient and the Darwin hash jobs stay idle.

## Platform keys

`opencode` shares one fixed-output hash across Linux architectures and keeps a
separate hash per Darwin architecture, matching upstream nixpkgs' split. The
hash file therefore uses:

```json
{
  "linux": "sha256-...",
  "aarch64-darwin": "sha256-...",
  "x86_64-darwin": "sha256-...",
  "version": "2.3.2"
}
```

The expression ignores `version`; it records the package version whose hashes
have been refreshed on every platform.

`platform_key()` in the updater maps any `*-linux` system to `linux` and uses
the exact system name otherwise.

`nixpkgs/overlays/overlay.nix` requires `nix-update` 1.17.0 or newer. Older
versions use `nix flake metadata`, which no longer copies a dirty flake to the
store on current Nix, so they fail after rewriting the version but before
fetching the new hashes. The flake exposes the fixed version as
`packages.<system>.nix-update`, and the development shell uses the same
overlay.

## Adding a package

Add an entry keyed by the flake package attribute:

```json
{
  "some-package": {
    "file": "nixpkgs/overlays/pkgs/some-package.nix"
  }
}
```

The package must be exposed as `packages.<system>.<attribute>` so `nix-update`
can evaluate it. Packaged source and dependency hashes that nix-update supports
are refreshed automatically. If a dependency hash differs by platform, put it in
a `hashFile` and use the `--src-only` path described below, so each runner
refreshes only its own value.

If the package also has a platform-specific fixed-output derivation, store its
hashes in a JSON file and read that file from the expression. Add `hashFile` and
`hashAttribute` to the manifest entry:

```json
{
  "some-package": {
    "file": "nixpkgs/overlays/pkgs/some-package.nix",
    "hashAttribute": "node_modules",
    "hashFile": "nixpkgs/some-package-hashes.json"
  }
}
```

Also extend the platform-hash trigger in `.github/workflows/main.yml` and the
Darwin commit paths when adding such a package.

## Manual use

Enter the development shell (it contains `nix-update`) and run:

```console
$ python3 scripts/update-tracked-packages.py --update-versions --system x86_64-linux
```

On each Darwin architecture, run the hash phase without `--update-versions`:

```console
$ python3 scripts/update-tracked-packages.py --system aarch64-darwin
$ python3 scripts/update-tracked-packages.py --system x86_64-darwin --mark-version
```

The final `--mark-version` records that every platform is current. If it is
missing, the next scheduled run repeats the Darwin hash phase.

`--no-verify` skips the post-update fixed-output rebuild. Run the
failure-handling tests with:

```console
$ python3 scripts/test-update-tracked-packages.py
```
