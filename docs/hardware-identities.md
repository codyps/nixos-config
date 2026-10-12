# Local hardware input and public CI fixtures

Production identifiers live in per-host SOPS files under `secrets/hardware/`.
`lib/hardware-identities-schema.json` names their consumers: filesystem UUIDs,
LUKS volume pins, ZFS host IDs, installation disk selectors, DHCP identities,
interface MAC addresses and USB device hashes. Passwords and private keys remain
separate runtime secrets.

The flake declares a non-flake input named `hardware-identities`. Its default is
a locked public snapshot of this repository, using only its
`config/hardware-fixtures` directory of deterministic synthetic values. This
avoids relative-input incompatibilities between Nix and Lix. Ordinary
Nix commands work on a fresh checkout without any decryption key. These default
builds are for tests and public caching; activation rejects them. Never run a
fixture Disko script on physical hardware.

## Production builds with normal Nix

No `nix` wrapper, shell alias, impure evaluation or custom rebuild executable is
needed. If you previously activated the wrapper, your next configuration
activation removes it; building alone does not change the installed commands.
Provision a machine-local deployment flake outside the checkout. It selects the
repository and decrypted hardware data as standard Nix inputs and forwards the
repository's outputs. Rebuilds use its path with no `--override-input`.

Before using this on a controller, make an authorized SOPS identity available to
your normal user: the administrator GPG private key, or an age key supplied via
SOPS's normal configuration (such as `SOPS_AGE_KEY_FILE`). The exporter decrypts
all host files, so that identity must have access to all of them. It never copies
private keys into the input. Build machines need no SOPS key once the input has
been provisioned.

From the checkout, bootstrap with the development shell:

```sh
nix develop
python3 scripts/hardware-identities.py --deployment "$HOME/.local/share/nixos-deployment"
```

After this configuration has been activated, the same exporter is available as:

```sh
sys hardware-deployment --repo "$PWD" "$HOME/.local/share/nixos-deployment"
```

Rerun this command after pulling or editing the repository or changing its SOPS
inventory. It refreshes **only the local deployment's lock**, leaving the
repository lock untouched. Git sources include tracked edits but exclude
untracked/ignored files; stage new source files before refreshing. Rebuilds use
the locked source snapshot until you refresh, even if the checkout has changed.
Failed decryption or lock refresh preserves the previous deployment. Do not run
a rebuild concurrently with provisioning.

To migrate an existing plaintext inventory without a SOPS key, add
`--inventory /absolute/path/to/hardware-identities.json`. That imports its current
values; it does not pick up subsequent encrypted inventory changes. For a
source-only refresh, rerun provisioning with
`--inventory /LOCAL/DEPLOYMENT/hardware-input/hardware-identities.json`.
Provisioning captures the tracked checkout as a store snapshot, including
tracked edits, then creates the local lock from the repository's dependency
lock. Updating the local lock alone does not select a newer checkout snapshot.

Build without activating:

```sh
nix build "path:$HOME/.local/share/nixos-deployment#nixosConfigurations.ward.config.system.build.toplevel" --no-link
nix build "path:$HOME/.local/share/nixos-deployment#darwinConfigurations.u3.system" --no-link
```

Choose the configuration for the machine being updated:

```sh
sudo nixos-rebuild boot --flake "path:$HOME/.local/share/nixos-deployment#ward"
sudo darwin-rebuild switch --flake "path:$HOME/.local/share/nixos-deployment#u3"
home-manager switch --flake "path:$HOME/.local/share/nixos-deployment#cody@arch1"
```

Here `$HOME` expands before `sudo`. NixOS `boot` prepares the next generation
without rebooting or switching running services. Platform builds still need a
compatible native or remote builder. A deployment can instead live at
`/etc/nixos` if that is an unused, machine-local location; keep the tracked
repository elsewhere. Provisioning refuses to overwrite an unmanaged flake.
With `/etc/nixos/flake.nix` provisioned, NixOS can use its normal default flake
location and hostname selection.

The deployment contains `flake.nix`, `flake.lock`, `deployment.json`, `hardware-input/`,
and a `source-root` GC-root symlink. The symlink keeps the source snapshot alive
across Nix garbage collection. Keep the entire directory out of Git and public caches. Its absolute input paths are
machine-local; rerun provisioning on a new controller. The local lock pins the
source and input in the local store, so archived deployments can also be copied
to trusted remote stores without the original checkout or decryption key.
Do not edit the generated flake or add unrelated files to this directory.

The lower-level `sys hardware-input` and `sys hardware-source` exporters remain
available. Their standalone input can still be used with
`--override-input hardware-identities path:/LOCAL/INPUT`; never write that
override into the repository lock. Production closures and their input paths
must never be pushed to public caches. Public dependencies remain reusable,
while files, initrds and systems depending on production values rebuild locally.

The input directory contains only `hardware-identities.json` and `metadata.json`.
The deployment and input directories have mode 0700; generated files have mode
0600. Both belong outside the checkout.
These permissions do not make copies in the Nix store confidential from local
users. Plaintext is allowed on trusted systems and in private caches, never in
Git, public logs or public caches.

## Remote rebuilding and installation

The optional remote helper provisions a temporary deployment from SOPS and
archives it and its inputs to the target store. The remote standard rebuild
command selects that archived flake without overrides or a decryption key:

```sh
nix run .#nixos-rebuild-remote -- ward build
nix run .#nixos-rebuild-remote -- ward boot
```

It expects an installed host with `cody@HOST` SSH and sudo access. It never
reboots; `switch` activates services immediately. A live installer uses the
host-specific installation guide instead.

The Warbler installer builds through a temporary deployment. After formatting,
it records the fresh volume pin in `/persist/nixos-config/hardware-input` and
creates `/persist/nixos-deployment` inside the installed system. Subsequent
rebuilds use `sudo nixos-rebuild boot --flake /persist/nixos-deployment#warbler`.
For source-only reprovisioning there, use:

```sh
sudo sys hardware-deployment --repo /persist/nixos-config \
  --inventory /persist/nixos-config/hardware-input/hardware-identities.json \
  /persist/nixos-deployment
```

For an attended fresh format, set only the local input's
`HOST.storage.luks.MAPPER.volumeKeyId` to `null`. MAPPER is `cryptroot` for Crow
and Warbler, and `luksroot` for Ward. Never clear a pin to bypass a mismatch on an
existing disk. After formatting, obtain `sudo sys root-volume-key-id` and record
it in both the local input and the corresponding encrypted host file before
refreshing the input or rebuilding elsewhere. SSH, account passwords and signing
keys retain their separate provisioning workflows.

## CI and validation

CI uses the committed fixture input directly, without SOPS keys or source
rewriting. Before building and before publishing, it resolves the actual input
through Nix and verifies the complete contents against the deterministic fixture
generator. Extra files, a production marker, or any different values prevent
publishing. Do not add whole-store uploads or public post-build hooks to a
production builder.

```sh
python3 scripts/test-hardware-identities.py
python3 scripts/test-warbler-install.py
nix eval --json .#lib.hardwareIdentityChecks
nix eval --json "path:$HOME/.local/share/nixos-deployment#lib.hardwareIdentityChecks"
```

The checks report booleans, not identifiers. After changing the schema, run
`python3 scripts/update-hardware-fixtures.py`. It generates fixtures from field
names alone. Never generate fixtures from production values.

The public default is pinned by `flake.lock`; it does not recursively evaluate
the snapshot's flake. When changing fixture fields, first publish the updated
schema and fixtures, then run `nix flake update hardware-identities` to select
that snapshot. Before publication, test with
`--override-input hardware-identities "path:$PWD/config/hardware-fixtures"`.
CI checks both the generated fixtures and the selected input, rejecting stale
schemas or mismatched fixture values. Ordinary dependency updates can refresh
the snapshot automatically.

## What remains local

Provisioning supplies explicit inputs; rebuilds do not decrypt SOPS or read an
ambient keyring. The repository itself stays reproducible with synthetic data.
A deployment lock is private machine state with an explicit refresh lifecycle,
not a replacement for the repository's dependency lock.
