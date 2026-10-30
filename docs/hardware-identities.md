# Machine-local hardware identities

Production identifiers live in per-host SOPS files under `secrets/hardware/`.
`lib/hardware-identities-schema.json` names their consumers: filesystem UUIDs,
LUKS volume pins, ZFS host IDs, installation disk selectors, DHCP identities,
interface MAC addresses and USB device hashes. Passwords and private keys remain
separate runtime secrets.

## Build and rebuild directly from the repository

All builds use the repository flake and its ordinary dependency lock. They need
no decryption key, hardware input override, Nix wrapper or local deployment flake:

```sh
nix build .#nixosConfigurations.ward.config.system.build.toplevel --no-link
nix build .#darwinConfigurations.u3.system --no-link
sudo nixos-rebuild boot --flake .#ward
sudo darwin-rebuild switch --flake .#u3
home-manager switch --flake '.#cody@arch1'
```

Choose the output for the target machine. Platform builds still need a compatible
native or remote builder. NixOS `boot` installs the next boot generation without
rebooting or switching running services.

NixOS installation and activation require provisioned local inventory, described
below. Building needs none. Darwin and Home Manager outputs do not consume this
inventory. Pulling source changes needs no separate provisioning or lock refresh.

## One-time provisioning on a NixOS target

Before the first installation or activation, provision the target's inventory.
The helper decrypts only `secrets/hardware/HOST.json` on that host, using its
existing Ed25519 SSH host identity as an age key. The encrypted file and schema
are part of the helper's build; no plaintext inventory is needed on a controller.
Build and run it on the target:

```sh
nix build .#nixosConfigurations.ward.config.system.build.hardwareProvisioner
sudo ./result/bin/hardware-runtime provision
```

Replace `ward` with the host. Its host identity must already be an authorized
recipient of its encrypted file. The helper uses the SSH key paths configured
for SOPS, or the Ed25519 OpenSSH host key paths when SOPS is not configured.
Key conversion happens locally; keys and decrypted values are never logged.

For recovery or a fresh installer without the target's host key, use an
administrator SOPS identity, or supply `--inventory /PRIVATE/host.json`.
The helper accepts the decrypted host file, a single-host export, or an older
combined inventory; it validates and retains only the target host's entry.
To export that single entry on a trusted controller:

```sh
nix develop
python3 scripts/hardware-identities.py --host ward /PRIVATE/ward-hardware
```

The exporter requires `--host` for production data and decrypts only that file.
It creates `hardware-identities.json` and metadata with private permissions.
It does not build a flake or modify Git. Transfer only through a trusted private
channel; never print the file in CI or paste it into logs. Existing recipient
access is preserved; host-scoped provisioning does not change SOPS key policy.

For a mounted installation, add `--root /mnt` to the provisioning command,
**after mounting persistent storage and before nixos-install**. Crow and Robin
also need provisioning without `--root` on the live installer before running
Disko: their installation disk selector is a local symlink. After formatting,
provision again under `/mnt`, using the intended new volume pin or `null` for
an attended first boot.

The helper validates and renders the inventory before replacing active state.
Missing files, invalid fields or synthetic fixture state prevent installation
and activation. Do not run provisioning concurrently with rebuilding.

After activation, the same operations are available as:

```sh
sudo sys hardware-provision
sudo sys hardware-verify
sudo nixos-rebuild boot --flake .#ward
```

Use `--repo "$PWD"` to decrypt the host file from a newer checkout rather than
the installed helper's encrypted snapshot. Reprovision when identifiers change;
ordinary source edits and pulls do not need it. Update the corresponding
encrypted SOPS file as well. Reprovisioning an old combined local inventory
removes the other hosts' entries without changing this host's values.
The new runtime can also read existing combined state. Keep that state until
rollback generations using the old full-inventory validator have been retired;
reprovisioning it with only one host makes those older generations incompatible.
A build alone does not change installed commands; activate the configuration
to install the current helpers.

## What happens locally

State lives at `/persist/nixos-hardware` on hosts with a `/persist` filesystem,
otherwise `/var/lib/nixos-hardware`. Its `input/` directory is mode 0700 and its
inventory files are mode 0600 and contain only that host. The `current` symlink selects generated runtime
files; those files are readable by services that need them. Plaintext identifiers
are acceptable on trusted systems.

Repository configurations refer to semantic `/dev/disk/by-hardware/...` aliases.
Local UUID mapping files supply these aliases through udev in both boot stages.
Live activation reloads the installed udev rules and replays block-device events
before restarting mounts. This registers the aliases with systemd; merely
creating filesystem symlinks does not satisfy `.device` dependencies.
Activation renders network drop-ins, USBGuard rules and the ZFS host ID from the
same inventory. Container network identities come from a read-only local bind
mount. After changing a container identity, restart that container during an
appropriate maintenance window so its bind mount selects the new generation.
Installation disk selectors remain under local state.

The bootloader's late initrd appender adds the actual crypttab pin, device
mappings, host ID and early network configuration directly to the initrd
**before PID 1 and its generators run**. It preserves other initrd secrets.
Lanzaboote then signs and measures that personalized image. Its installer is
patched to refresh generations with local initrd inputs even when their store
path has not changed.

Thus the Nix store build remains reusable, while installed ESP boot files and
runtime files contain production identifiers. Secure Boot verification, pinned
LUKS volume validation, TPM policy updates and sealed recovery credentials remain
in the existing staged provisioning workflow. Do not upload personalized ESP
files or local state to public storage.

For a freshly formatted LUKS volume only, a `null` value at
`HOST.storage.luks.MAPPER.volumeKeyId` permits an attended first boot and omits
TPM unlock options. MAPPER is `cryptroot` for Crow/Warbler and `luksroot` for Ward.
Never clear a valid pin to bypass a mismatch on an existing disk. Obtain
`sudo sys root-volume-key-id` on the trusted installed system, update the private
inventory and encrypted source, provision, then rebuild. See
[secure unlock](secure-unlock.md) for firmware enrollment and TPM enrollment.

## Remote builds and installation

The optional helper archives the repository to the target and invokes the
standard rebuild command there:

```sh
nix run .#nixos-rebuild-remote -- ward build
nix run .#nixos-rebuild-remote -- ward boot
```

It expects `cody@HOST` SSH and sudo access. The target must already be provisioned
for boot/switch actions; no production inventory is sent to a builder. It never
reboots. `switch` activates services immediately.

The Warbler installer keeps its private seed inventory outside the source used
for building. After formatting it records the new volume pin, provisions
`/mnt/persist/nixos-hardware`, installs the system, and removes the temporary
seed from the live installer. The seed is never copied into the installed checkout. Subsequent rebuilds use
`sudo nixos-rebuild boot --flake /persist/nixos-config#warbler`.

## CI and validation

CI builds the same pure outputs used by production machines. Committed
deterministic fixtures are template markers and test data, not installable
machine identities. Before public uploads CI verifies those files against the
fixture generator. It has no production decryption key. Production host
installation rejects fixture state; tests must explicitly enable test fixtures
or supply invented test inventory.

Do not enable public whole-store upload hooks on trusted production builders.
They may still contain older identity-dependent builds or unrelated private data.
Only the reviewed pure outputs of this design are intended for public CI caching.

```sh
python3 scripts/test-hardware-identities.py
python3 scripts/test-hardware-runtime.py
python3 scripts/test-warbler-install.py
python3 scripts/test-secure-unlock-setup.py
nix eval --json .#lib.hardwareIdentityChecks
nix build .#checks.x86_64-linux.warbler-vm --no-link
```

After schema changes, run `python3 scripts/update-hardware-fixtures.py`.
Fixtures derive from field names only and are committed with the schema; there
is no hardware flake input to update. Successful builds prove evaluation and
construction, not host activation or physical firmware/TPM behavior.
