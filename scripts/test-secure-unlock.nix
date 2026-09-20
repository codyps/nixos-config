# nix eval --impure --json --file scripts/test-secure-unlock.nix
let
  flake = builtins.getFlake ("path:" + toString ../.);
in
import ../nixos-modules/secure-unlock/test.nix {
  nixpkgs = flake.inputs.nixpkgs;
  module = flake.nixosModules.secure-unlock;
}
