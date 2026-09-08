# Configuration cache pilot

Run **Configuration cache pilot** from GitHub Actions using **Run workflow**.
It is manual-only: no push, PR, daily update, or deployment triggers are added.
The workflow must exist on the default branch for GitHub's manual-run UI.

Each run discovers all NixOS, standalone Home Manager, and Darwin configurations
from the selected revision and builds each on its native platform. Up to four
jobs run concurrently; one failed build does not cancel the others. Embedded
Home Manager profiles are included in their parent system closure.

Publishing defaults to enabled, but only runs on `master`. Disable the input for
a build-only pilot. Branch runs always build without publishing. The workflow
uses the existing `CACHIX_CACHE` variable and `CACHIX_AUTH_TOKEN` secret.
Only the publishing step receives the token (apart from the credential check).

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

Use the first run to identify evaluation failures, missing substitutes, and
disk-heavy configurations. Compare subsequent runs to assess cache reuse.
There is deliberately no aggressive runner cleanup, so the pilot measures the
normal runner environment. A configuration that exceeds available space needs
targeted cleanup or a larger builder before enabling scheduled builds.

The pilot pushes runtime closures. It does not activate systems, install
Homebrew packages, or cache every intermediate build dependency. Cachix retention
and client substituter configuration remain separate operational concerns.
