final: prev: {
  targo = with prev; (callPackage ./pkgs/targo.nix {
    inherit fetchFromGitHub rustPlatform;
  });
}
