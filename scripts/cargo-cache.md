# Cargo caching with mbx

Shared Home Manager profiles enable `programs.mbx` to wrap plain `cargo` with
[mr-boxington](https://github.com/jdx/mr-boxington). The warbler-ai NixOS
container installs the same upstream shim declaratively.
Home Manager installs upstream's exact standalone launcher and `mbx-target`
under `~/Library/Application Support/mbx/bin` on macOS, or
`$XDG_DATA_HOME/mbx/bin` on Linux, and prepends that directory to PATH.
The launcher is extracted from the selected package's source without changing
its shebang, so `mbx doctor` recognizes it as current. `mbx-target` points at
that package's Nix store executable and updates with the Home Manager generation.
Upstream removes only the dedicated shim directory before finding real Cargo
in the shared profile (`programs.mbx.cargoPackage`, Rustup by default).
No mutable `mbx setup` step is needed. Open a new shell after activation to load
the new PATH. `MBX_DISABLE=1 cargo build` bypasses caching. Existing target links
and cache contents are not migrated or deleted by this switch.

The shared shell profile no longer sets `RUSTC_WRAPPER`. After activating this
change, run `unset RUSTC_WRAPPER` in existing shells to clear the old setting.

Run `python3 scripts/test-mbx.py /path/to/home-manager-generation` to test the
built generation's files and session PATH with an isolated home, cache, and Rust
project. It also requires `mbx doctor`'s setup check to pass.

## Nix binary cache for mbx

`nix build .#mbx` builds the same package used by the Home Manager module.
The shared `Build and cache flake outputs` workflow discovers it natively for
`x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, and `aarch64-darwin`.
Each package build runs its Nix checks. Pull requests build without publishing;
pushes to `main` and manual runs on `main` publish the resulting package
and its runtime closure to Cachix. Build-only dependencies and temporary test
outputs are not selected for upload.

The nightly flake-update workflow also calls this workflow with the exact
updated commit, since commits made using `GITHUB_TOKEN` do not trigger push
workflows.

The public cache is `codyps` at `https://codyps.cachix.org`, with its signing
public key declared in `flake.nix`. Repository setup uses these settings in
[the repository's Actions settings](https://github.com/codyps/nixos-config/settings/secrets/actions):

- Repository variable `CACHIX_CACHE`: `codyps`.
- Repository secret `CACHIX_AUTH_TOKEN`: a write token scoped to that cache.

Run `gh workflow run configurations-pilot.yml --ref main` to populate the cache on demand.
Consumers need the cache URL in `extra-substituters` and its public signing key
in `extra-trusted-public-keys`, or can run `cachix use CACHE_NAME` to configure
them. Never put the write token in Nix files. The cache reuses exact Nix store
paths, so consumers must use matching flake inputs and package definitions.
This caches the mbx executable; Rust compilation caches managed by mbx remain
separate.

On Windows, use upstream mbx setup. Remove any legacy cargo-target helpers
from the user PATH before using mbx.
