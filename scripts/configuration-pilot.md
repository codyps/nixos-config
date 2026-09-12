# Automatic flake caching

**Build and cache flake outputs** runs on every push to `main` and on pull
requests. The daily flake updater explicitly calls it with the exact commit it
created, because commits made with `GITHUB_TOKEN` do not trigger push workflows.
It remains manually runnable from Actions; the historical workflow filename is
`configurations-pilot.yml`.

Each run discovers all NixOS, standalone Home Manager, and Darwin configurations,
plus every `packages.<system>` output, from the selected revision. Targets build
on native runners, with up to four jobs concurrently and independent failures.
Embedded Home Manager profiles are included in their parent system closure.

Standalone package jobs preserve coverage where no configuration selects a
package. Currently this includes mbx on both ARM platforms and custom Caddy on
ARM Linux and both Darwin platforms. All exported packages are included, so no
package-specific workflow list needs maintenance. Shared dependencies reuse
Cachix; concurrently started cold builds may still duplicate work.

Successful `main` push and updater builds publish runtime closures to Cachix.
PRs and manual branch runs never publish. Manual runs on `main` publish by
default; disable the `publish` input for a build-only run. The workflow uses the
existing `CACHIX_CACHE` variable and `CACHIX_AUTH_TOKEN` secret. Only publishing
and its credential preflight receive the token.

Each build has a 180-minute limit and reports:

- Build duration and exit code.
- Initial free space, minimum sampled free space, and peak sampled disk growth
  on the filesystem containing `/nix/store`, sampled approximately every two
  seconds. This includes build scratch space only when it shares that filesystem;
  it is not a measurement of Nix store size or an exact instantaneous peak.
- Successful root's uncompressed runtime closure size, not uploaded bytes.
- Cachix publishing output in `publish.log`, including its transfer statistics.

Measurements appear in the job summary and in per-job artifacts retained for
14 days. Nix build logs are streamed to the Actions log. Ordinary build failures
still produce measurements; forced cancellation, job timeout, or disk exhaustion
can prevent final report/artifact writes. Installer or matrix failures occur
before measurement begins.

Use run measurements to identify evaluation failures, missing substitutes, and
disk-heavy configurations. Compare subsequent runs to assess cache reuse.
There is deliberately no aggressive runner cleanup, so the pilot measures the
normal runner environment. A configuration that exceeds available space needs
targeted cleanup or a larger builder to keep automatic builds reliable.

The workflow pushes runtime closures. It does not activate systems, install
Homebrew packages, or cache every intermediate build dependency. Cachix retention
remains a separate operational concern.

`modules/nix-cache.nix` reuses the flake's cache URLs and signing keys in every
NixOS, Darwin, and standalone Home Manager configuration. The workflow verifies
these settings and evaluation of each generated `nix.conf` before building.
Activate the updated system or Home Manager generation to install the settings.
Embedded Home Manager users inherit their system's daemon cache configuration.
On standalone Home Manager installations using a separately managed multi-user
daemon, its administrator must also authorize the cache if the user is untrusted.
The Docker builder's `nix.conf` carries matching settings; rebuild/recreate the
builder using its setup instructions to apply them to an existing container.
