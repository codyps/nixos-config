# Custom Caddy CI

`packages.<system>.caddyFull` is the same plugin-enabled Caddy used by the
host overlay. The shared **Build and cache flake outputs** workflow discovers it
on all four platforms, along with the Linux source-bundle outputs. Nixpkgs'
install checks verify plugin versions. Successful main builds publish the
binary and runtime closure using `CACHIX_CACHE` and `CACHIX_AUTH_TOKEN`.
Pull requests build without publishing. There is no separate Caddy workflow.
The shared workflow also runs the hash updater's failure-handling tests.

The scheduled/manual flake-update workflow runs `nix flake update`, then
`python3 scripts/update-caddy-hashes.py` on Linux. The updater forces a fresh
plugin source fetch with a fake hash for each nixpkgs input, accepts only the
hash mismatch belonging to that exact source derivation, and rebuilds both
sources with the discovered hashes. Other failures abort the update. It
restores the original hash file if verification fails.

Both hashes live in `nixpkgs/caddy-hashes.json`, because Intel macOS uses the
separately pinned `nixpkgs-darwin` input. Source bundles are generated on Linux;
the platform matrix checks that they work for each native Caddy build.
The update commits this file together with `flake.lock`, then explicitly calls
the shared cache workflow with the resulting commit (token-generated commits do not
trigger push workflows). Binary build failures fail CI after the update commit;
they do not roll it back.

For a manual flake/plugin update, run the updater on Linux before committing.
Run its failure-handling tests with `python3 scripts/test-update-caddy-hashes.py`.
