# Repository Guidelines

## Project Structure & Module Organization

`flake.nix` defines NixOS, nix-darwin, Home Manager, package, and development-shell outputs; `flake.lock` pins dependencies. Host-specific settings live in `hosts/<hostname>/`. Shared configuration lives in `nixos/`, `nix-darwin/`, and `home-manager/`; reusable modules are in `modules/` and `nixos-modules/`. Package overrides live in `nixpkgs/`. Supporting tools and tests are in `scripts/`, application configuration in `config/`, and image assets in `images/`. GitHub Actions workflows live in `.github/workflows/`.

## Build, Test, and Development Commands

- `nix develop`: enter the development shell with SOPS, age, and related key-management tools; `.envrc` also supports direnv.
- `nix fmt`: format Nix code using the flake's `nixpkgs-fmt` formatter. Keep formatting changes scoped to your work.
- `nix flake check --no-build`: check flake evaluation without building outputs.
- `nix build .#nixosConfigurations.robin.config.system.build.toplevel --no-link`: build a NixOS system without activation; replace `robin` with the affected host.
- `nix build .#darwinConfigurations.u3.system --no-link`: build the macOS configuration without activation.
- `python3 scripts/test-configuration-pilot.py` and `python3 scripts/test-update-caddy-hashes.py`: run the Python tests used by CI.

Use a compatible native runner or configured remote builder for platform-specific builds.

## Coding Style & Naming Conventions

Follow existing Nix formatting: two-space indentation, explicit attribute sets, and small reusable modules. Use descriptive kebab-case filenames such as `nix-cache.nix`. Keep host-specific choices under `hosts/`; move shared behavior into the appropriate common module. Preserve the separate Intel Darwin dependency set when changing flake inputs.

## Testing Guidelines

Python helper tests use `unittest`; follow the existing `test-*.py` and `test_*` method conventions. Run tests for changed helpers and build affected configuration outputs. No numeric coverage threshold is configured. CI discovers and builds exported configurations and packages; successful builds do not prove activation or running-service behavior.

## Commit & Pull Request Guidelines

Use concise imperative commit subjects, following history: `Configure shared Cachix caches across all systems and homes`. Keep commits focused. PR descriptions should identify affected hosts, explain behavior changes, and list validation results and platform limitations. Report activation separately from evaluation and builds.

## Secrets & Configuration

Keep secrets encrypted with SOPS using `.sops.yaml`; never commit decrypted credentials or private keys. Review host-specific documentation before installation, disk changes, or deployment.
