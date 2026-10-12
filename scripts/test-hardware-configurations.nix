import ./check-hardware-configurations.nix {
  flake = builtins.getFlake ("path:" + toString ../.);
}
