# Local hardware input and public CI fixtures

Production identifiers live in per-host SOPS files under `secrets/hardware/`.
`lib/hardware-identities-schema.json` names their consumers: filesystem UUIDs,
LUKS volume pins, ZFS host IDs, installation disk selectors, DHCP identities,
interface MAC addresses and USB device hashes. Passwords and private keys remain
separate runtime secrets.

The flake declares a non-flake input named `hardware-identities`. Its default is
`config/hardware-fixtures`, containing deterministic synthetic values. Ordinary
Nix commands work on a fresh checkout without any decryption key. These default
builds are for tests and public caching; activation rejects them. Never run a
fixture Disko script on physical hardware.

## Production builds with normal Nix

No `nix` wrapper, shell alias, impure evaluation or custom rebuild executable is
needed. If you previously activated the wrapper, your next configuration
activation removes it; building alone does not change the installed commands.
Provision a small local input directory once, then select it with Nix's
standard `--override-input` option. Refresh that directory after edits or pulls that change the
SOPS files or their schema. Provisioning validates the schema and atomically replaces the data;
failed decryption leaves the previous input intact.

Before using this on a controller, make an authorized SOPS identity available to
your normal user: the administrator GPG private key, or an age key supplied via
SOPS's normal configuration (such as `SOPS_AGE_KEY_FILE`). The exporter decrypts
all host files, so that identity must have access to all of them. It never copies
private keys into the input. Build machines need no SOPS key once the input has
been provisioned.

From the checkout, bootstrap with the development shell:

```sh
nix develop
python3 scripts/hardware-identities.py "$HOME/.local/share/nixos-hardware"
```

After this configuration has been activated, the same exporter is available as:

```sh
sys hardware-input --repo "$PWD" "$HOME/.local/share/nixos-hardware"
```

`sys hardware-source` remains an alias for the exporter. The former whole-source
`prepare`/`run` interface is removed. An existing plaintext inventory can be
migrated with `--inventory /absolute/path/to/hardware-identities.json`.

Build without activating:

```sh
nix build .#nixosConfigurations.ward.config.system.build.toplevel --no-link \
  --override-input hardware-identities "path:$HOME/.local/share/nixos-hardware"

nix build .#darwinConfigurations.u3.system --no-link \
  --override-input hardware-identities "path:$HOME/.local/share/nixos-hardware"
```

Use the same flag with ordinary rebuild commands. Choose the configuration for
the machine being updated:

```sh
sudo nixos-rebuild boot --flake .#ward \
  --override-input hardware-identities "path:$HOME/.local/share/nixos-hardware"

sudo darwin-rebuild switch --flake .#u3 \
  --override-input hardware-identities "path:$HOME/.local/share/nixos-hardware"
```

Here `$HOME` expands in your shell before `sudo`; root can read the private local
input. NixOS `boot` prepares the next boot generation without rebooting or
switching running services. Standalone `home-manager switch` accepts the same
flake input override. Platform builds still need a compatible native or remote
builder.

`--override-input` implies `--no-write-lock-file`: the committed lock keeps the
synthetic input, and the production directory and its hash are not recorded in
Git. Do not use `--write-lock-file` with production input overrides. The input is
copied to the local store; production closures and their input paths must never
be pushed to public caches. Public dependencies remain reusable, while files,
initrds and systems that depend on production values rebuild locally.

The input directory contains only `hardware-identities.json` and `metadata.json`.
It has mode 0700 and its files have mode 0600. It belongs outside the checkout.
These permissions do not make copies in the Nix store confidential from local
users. Plaintext is allowed on trusted systems and in private caches, never in
Git, public logs or public caches.

## Remote rebuilding and installation

The optional remote helper still provisions from SOPS and transfers the checkout
and local input to the target store. It supplies the same override to the remote
standard rebuild command, so the target needs no production decryption key:

```sh
nix run .#nixos-rebuild-remote -- ward build
nix run .#nixos-rebuild-remote -- ward boot
```

It expects an installed host with `cody@HOST` SSH and sudo access. It never
reboots; `switch` activates services immediately. A live installer uses the
host-specific installation guide instead.

The Warbler installer transfers a separate `hardware-input` directory alongside
the source, supplies the override for every evaluation/build, and retains it at
`/persist/nixos-config/hardware-input`. Its pin is updated after formatting. A
manual rebuild of that installed checkout must select that local directory with
`--override-input hardware-identities path:/persist/nixos-config/hardware-input`.

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
nix eval --json .#lib.hardwareIdentityChecks \
  --override-input hardware-identities "path:$HOME/.local/share/nixos-hardware"
```

The checks report booleans, not identifiers. When the schema changes, regenerate
the synthetic input outside the checkout with `--fixtures`, verify it, and copy
only those two synthetic files to `config/hardware-fixtures`; update its lock.
Never generate fixtures from production values.

## Removing the override flag later

The remaining flag selects a build input; it is not a decryption hook. Pure Nix
cannot silently read undeclared local files or invoke the user's SOPS keyring.
A separate local deployment flake can select this input using standard Nix, but
adds a local lock/update lifecycle.

A more extensive redesign would supply identities at runtime or during local
boot-image installation. Network and USB settings are candidates for runtime
files. Root device selection, ZFS host IDs and LUKS volume pins require early-boot
provisioning, with the pins covered by the Secure Boot/TPM trust chain. They must
be available before unlocking root; decrypting them from that root at normal
service startup is too late. That work is separate from this input refactor.
