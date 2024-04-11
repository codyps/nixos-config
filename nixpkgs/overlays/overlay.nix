final: prev: {
  targo = with prev; (callPackage ./pkgs/targo.nix {
    inherit fetchFromGitHub rustPlatform;
  });
  
  # Workaround for nix+zig bug on darwin
  # https://github.com/NixOS/nixpkgs/issues/287861#issuecomment-1962225863
  ncdu = prev.ncdu.overrideAttrs {
    __noChroot = prev.ncdu.stdenv.isDarwin;
  };

  zig_0_11 = prev.zig_0_11.overrideAttrs {
    __noChroot = prev.zig_0_11.stdenv.isDarwin;
  };
}
