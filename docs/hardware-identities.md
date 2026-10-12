# Local hardware settings and public CI fixtures

Production hardware identifiers live in `secrets/hardware/HOST.json`, encrypted
with SOPS. `lib/hardware-identities-schema.json` describes each host's required
fields. Fields name their consumers, for example:

- `storage.fileSystems."/boot".uuid`
- `storage.luks.cryptroot.volumeKeyId`
- `storage.installationDisk.byId`
- `storage.zfs.hostId`
- `network.interfaces.eno1.dhcp.duid` and `.iaid`
- `network.interfaces.wlp6s0.permanentMacAddress`
- `network.containers.warbler-ai.interfaces.mv-eno1.macAddress`
- `usb.devices.logitechReceiver.descriptorHash`

Plaintext identifiers may exist on trusted machines, in their local Nix stores,
and in private caches. They must not be committed, logged in public CI, or
uploaded to public caches. This policy does not make the local store confidential
from other local users. Passwords and private keys remain separate runtime SOPS
secrets and never enter these build inputs.

## Ordinary Nix commands

### First use on an existing machine

Pulling the repository does not install the wrapper. Until you activate a new
system or Home Manager generation, use the explicit helper below. You need Nix
with flakes enabled and a SOPS identity authorized by `.sops.yaml`: either the
administrator's GPG private key in your user keyring, or an authorized age key
available to SOPS (for example through `SOPS_AGE_KEY_FILE`). The helper currently
decrypts all host files, so that identity must have access to all of them. No
GitHub or Cachix token is needed to build.

From the checkout, enter the development shell (it provides Python, Git and
SOPS), then build without activation:

```sh
git pull --rebase
nix develop
python3 scripts/hardware-identities.py run -- nix build .#nixosConfigurations.ward.config.system.build.toplevel --no-link
```

For a local macOS build, replace the build target with
`.#darwinConfigurations.u3.system`, or the configuration for your Mac. Platform
builds still require a native or configured remote builder.

To install the wrapper on the controller, activate its configuration once using
the helper. Choose the command for that controller and replace `HOST` with its
configuration name:

```sh
# NixOS controller
python3 scripts/hardware-identities.py run -- sudo nixos-rebuild switch --flake .#HOST
# macOS controller with darwin-rebuild already installed
python3 scripts/hardware-identities.py run -- sudo darwin-rebuild switch --flake .#HOST
# Standalone Home Manager controller
python3 scripts/hardware-identities.py run -- home-manager switch --flake .#HOST
```

Run the helper as your normal user so it can access that user's SOPS identity;
only the rebuild command needs `sudo`. Open a fresh login shell after activation
and leave the development shell so its upstream `nix` does not shadow the managed
wrapper. Merely building the configuration does not install it.

For a remote NixOS host that already accepts `cody@HOST` SSH and sudo, the packaged
helper handles source preparation and transfer even before the wrapper is installed:

```sh
nix run .#nixos-rebuild-remote -- ward build
# Install as the next boot generation, without rebooting:
nix run .#nixos-rebuild-remote -- ward boot
```

Use `switch` instead of `boot` only when you intend to activate services now.
This helper is for an installed host; a live installer accessed as `nixos@nixos`
uses the host's installation guide instead.

### After activation

The shared hardware module installs a `nix` wrapper ahead of the configured Nix
executable. After activating that module on a controller, ordinary commands work:

```sh
nix build .#nixosConfigurations.crow.config.system.build.toplevel --no-link
nix flake check --no-build
nix develop
nix eval --impure --json --file scripts/test-crow.nix
```

For this repository's local flake references, the wrapper decrypts the host files
with the user's existing SOPS identity, validates them, and prepares a temporary
source outside Git. It forwards local flake references to that source while
preserving the caller's working directory, relative output links, and arguments
after `--`. `nix develop` therefore opens in the original checkout. Preparation
includes tracked edits and nonignored untracked files. Failure to decrypt stops
the command; production builds never silently fall back to fixtures.

Decryption is cached under `$XDG_CACHE_HOME/nixos-hardware` (default
`~/.cache/nixos-hardware`), with directory mode 0700 and file mode 0600. The cache
key covers the schema and encrypted files, so changing either causes decryption
and validation again. SOPS keys themselves are not copied. Old cache entries may
be deleted at any time. Provision a SOPS identity before the first build on a new
controller; automatic preparation cannot replace that initial trust setup.

Other repositories, remote flake references, `nix fmt`, and `nix flake update`
pass through unchanged. Arbitrary `--expr` strings are not rewritten. Code that
constructs a flake reference inside an expression should use the explicit helper
below. Programs invoking Nix by an absolute store path bypass the wrapper.

Before the wrapper is installed, or when preparing a source for an installer:

```sh
nix develop
python3 scripts/hardware-identities.py run -- nix build .#nixosConfigurations.crow.config.system.build.toplevel --no-link
python3 scripts/hardware-identities.py prepare /private/tmp/nixos-prepared
```

On managed systems these operations are also available through
`sys hardware-source`. A destination must be absent and outside the checkout.
`--inventory /absolute/path/to/local.json` supplies an existing validated inventory
for recovery. A prepared source can be prepared again without decryption keys.
Never copy its `hardware-identities.json` or `.hardware-source-files.json` back
into Git. Local source snapshots are production data, even if only some hosts
are being built.

`nix run .#nixos-rebuild-remote -- HOST [ACTION]` prepares and transfers a local
source before rebuilding on the target. It does not reboot. Direct installation
and rebuild tools that bypass the managed `nix` executable must receive a prepared
source explicitly.

## Provisioning and editing

Edit a host with `sops secrets/hardware/HOST.json`. Update its schema and consumers
together when adding fields. Recipients retain the existing administrator and
trusted-controller access; the public CI recipient is excluded. Files are split
by host for clarity, not to claim isolation between those existing recipients.

For an attended fresh format of Crow, Warbler, or Ward, set only the prepared
source's `storage.luks.MAPPER.volumeKeyId` to `null`. The mapper is `cryptroot` on
Crow and Warbler, and `luksroot` on Ward. Never clear a pin to bypass a mismatch
on an existing disk. After formatting, obtain the new pin with
`sudo sys root-volume-key-id`, and record it in both the local prepared inventory
and the host's encrypted source before future rebuilds.

The Warbler installer clears only its disposable source's pin, then writes the
new pin into `/persist/nixos-config/hardware-identities.json`. Transfer that pin
to `secrets/hardware/warbler.json` through SOPS before rebuilding from another
checkout. Installed sources from the older flat schema must be freshly prepared
with this version before use. SSH keys, passwords, and signing keys continue to
use their separate provisioning bundle.

## Public builds and caching

CI runs `hardware-identities.py --fixtures prepare DEST` without a decryption key.
Fixtures are deterministic, syntactically valid synthetic identifiers generated
from field names alone. Every exported configuration remains in the build matrix,
including pull requests without secrets. The fixture source has an explicit
marker; generated system activation and NixOS pre-switch checks reject it.
Fixture systems are for compilation and caching, not installation or booting.
Never use fixture Disko scripts on a physical machine.

Before pushing any closure, CI checks that the inventory exactly equals the
synthetic generator's result. A marker alone is insufficient. The publishing job
must build from that same prepared source, with no production decryption key or
local production inventory. Do not add `cachix watch-store`, a public post-build
hook, or a whole-store upload on a production builder.

Most packages, kernels, and dependencies share store paths between fixture and
production builds and can be downloaded from the public cache. Identity-dependent
configuration files, initrds, boot images, and their dependent outputs rebuild
locally. This is not limited to text files, and the amount of rebuilding depends
on the dependency graph. Successful fixture builds establish compilation coverage,
not correct physical device selection or successful activation of a real host.

## Validation

```sh
python3 scripts/test-hardware-identities.py
python3 scripts/test-hardware-nix.py
python3 scripts/test-warbler-install.py
nix eval --impure --json --file scripts/test-crow.nix
nix eval --impure --json --file scripts/test-ward.nix
nix eval --impure --json --file scripts/test-warbler-volume-key.nix
```

Check production evaluations locally as well as fixture builds. Keep values out
of logs and review output; compare them in memory and report only pass/fail.
