# Wren

Intel Mac mini (Macmini8,1), six-core 3.2 GHz Core i7 and 32 GiB RAM.
Initial setup targets macOS 15.8.1 and the existing `cody` account at `/Users/cody`.

The flake uses the separate pinned Nixpkgs, nix-darwin, and Home Manager 26.05
inputs for Intel Darwin. It manages Lix and includes the shared Darwin and
Home Manager configuration. The common cache module permanently configures
`nix-community.cachix.org` and `codyps.cachix.org` with their signing keys;
Wren also enables permanent acceptance of flake configuration.

Build without activation:

```sh
nix build .#darwinConfigurations.wren.system --no-link
```

For the initial activation with the existing multi-user Lix installation:

```sh
nix build .#darwinConfigurations.wren.system
sudo ./result/sw/bin/darwin-rebuild switch --flake .#wren
```

Subsequent rebuilds:

```sh
sudo darwin-rebuild switch --flake .#wren
```

Activation changes the computer name and local hostname to `wren` and installs
the shared user configuration. Review any Home Manager file-collision errors
and preserve existing files before retrying activation.
