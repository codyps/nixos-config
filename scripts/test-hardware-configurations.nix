import ./check-hardware-configurations.nix {
  flake = builtins.getFlake ("git+file://" + toString ../.);
}
