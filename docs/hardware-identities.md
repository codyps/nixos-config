# Hardware identities outside Git

`secrets/hardware-identities.json` is the SOPS-encrypted source for host disk
selectors, filesystem/LUKS UUIDs, ZFS host IDs, DHCP identities, fixed container
MAC addresses, USBGuard fingerprints, and root-volume identity pins.
`lib/hardware-identities-schema.json` lists the required hosts, fields, and types
without their values. Synthetic VM/test identifiers and protocol constants are
not production inventory.

The confidentiality boundary is Git. Decrypted identifiers are allowed in
prepared source snapshots, the Nix store, generated system configuration, initrds,
and binary caches. Passwords, private keys, and other secrets must not be put in
this inventory. Existing Git history is not rewritten by this mechanism.

## Builds and remote rebuilds

Nix needs these values during evaluation, before runtime SOPS activation.
The preparation helper decrypts the inventory and copies source into a new
location outside the checkout. It includes tracked edits and untracked source
files, preserves tracked deletions, and excludes Git-ignored files. It refuses
tracked plaintext inventory, external symlinks, and an existing destination.
Missing or malformed inventory stops the operation; it never invents identifiers.

On a system with the administration command installed:

```sh
sys hardware-source run -- nix build .#nixosConfigurations.crow.config.system.build.toplevel --no-link
sys hardware-source run -- nix flake check --no-build
```

Before activating the command, use Python with SOPS and Git on PATH:

```sh
nix develop
python3 scripts/hardware-identities.py run -- nix build .#nixosConfigurations.crow.config.system.build.toplevel --no-link
```

`run` executes the command inside a temporary prepared checkout and removes it
when the command exits. Use `prepare` for installation or multiple commands:

```sh
python3 scripts/hardware-identities.py prepare /private/tmp/nixos-prepared
cd /private/tmp/nixos-prepared
nix build .#nixosConfigurations.crow.config.system.build.toplevel --no-link
```

The destination must not already exist. Use a suitable path on Linux.
A prepared checkout has no `.git`; Nix therefore includes its local
`hardware-identities.json`. Never copy that file into tracked source or force-add
it to Git. The accompanying `.hardware-source-files.json` allows another snapshot
to be prepared from the installed copy without access to the SOPS key.
`--inventory /absolute/path/to/hardware-identities.json` can explicitly supply an
existing local inventory before `run` or `prepare`.

`nix run .#nixos-rebuild-remote -- HOST [ACTION]` performs preparation on the
controller, archives the prepared source and inputs to the target's Nix store,
and rebuilds there. The controller needs a SOPS decryption key. It never reboots.
Direct `nixos-rebuild` and installation commands must use a prepared checkout.

## Installation and changing identifiers

Edit the encrypted inventory with `sops secrets/hardware-identities.json`.
For a new field, update the schema and its configuration reference together.
Do not paste values into documentation, tests, commit messages, or logs.
Only hardware inventory belongs here; the Actions recipient must not gain access
to unrelated SOPS files.

For a fresh format of Crow, Warbler, or Ward, set that host's `rootVolumeKeyId`
to `null` in the **prepared checkout's local inventory** before building the
attended installation. Other selectors must still identify the intended device.
Never clear a pin merely to work around an existing disk's identity mismatch.
After formatting, obtain the new pin using `sudo sys root-volume-key-id` and
record it in the prepared inventory and the SOPS-encrypted source before future
rebuilds. The tiny `hosts/HOST/volume-identity.nix` files only read the inventory;
do not replace them with literal values.

The Warbler installer prepares inventory before transfer, clears the pin only
in the disposable install source, and records the freshly installed disk's pin
in `/persist/nixos-config/hardware-identities.json`. Copy that new pin into the
encrypted inventory before rebuilding from another checkout. Its passwords,
SSH private keys, and signing keys continue to use the separate provisioning
bundle and never enter the prepared flake.

## CI and validation

Actions uses the dedicated `HARDWARE_IDENTITIES_AGE_KEY` repository secret to
prepare its source under `RUNNER_TEMP`. The corresponding age recipient is
limited to this inventory file. Main-branch and scheduled builds fail if the key
is missing. Pull requests without secret access omit NixOS configuration targets
and report that limitation; package, Home Manager, and Darwin jobs remain.
Inventory-free helper tests still run. Such runs do not validate NixOS builds.

```sh
python3 scripts/test-hardware-identities.py
python3 scripts/test-warbler-install.py
sys hardware-source run -- nix eval --impure --json --file scripts/test-crow.nix
sys hardware-source run -- nix eval --impure --json --file scripts/test-ward.nix
sys hardware-source run -- nix eval --impure --json --file scripts/test-warbler-volume-key.nix
```

SOPS recipients decrypt during provisioning; the installed boot path has no new
SOPS dependency. Initrd network matches, disk selectors, and volume pins retain
their existing values, even before encrypted `/persist` is available.
