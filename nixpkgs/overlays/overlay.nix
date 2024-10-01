final: prev: rec {
  targo = with prev; (callPackage ./pkgs/targo.nix {
    inherit fetchFromGitHub rustPlatform;
  });

  # Workaround for nix+zig bug on darwin
  # https://github.com/NixOS/nixpkgs/issues/287861#issuecomment-1962225863
  #ncdu = prev.ncdu.overrideAttrs {
  #  __noChroot = prev.ncdu.stdenv.isDarwin;
  #};

  #zig_0_11 = prev.zig_0_11.overrideAttrs {
  #  __noChroot = prev.zig_0_11.stdenv.isDarwin;
  #};
  # https://github.com/NixOS/nixpkgs/issues/317055
  # https://github.com/khaneliman/khanelinix/commit/93d76d630a0fa906bcd3e860777a35321db80975
  zig_0_12 = prev.zig_0_12.overrideAttrs (_oldAttrs: {
    preConfigure = ''
      CC=$(command -v $CC)
      CXX=$(command -v $CXX)
    '';
  });

  s2 = with prev; (callPackage ./pkgs/s2.nix {
    inherit fetchFromGitHub lib buildGoModule;
  });

  dagger = prev.callPackage ./pkgs/dagger {
    inherit dagger;
  };

  redpanda-connect = prev.callPackage ./pkgs/redpanda-connect {};
}
