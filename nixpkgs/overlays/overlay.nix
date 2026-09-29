(final: prev: ({
  # cargo-generate 0.25.0 moved should_canonicalize to utils::tests, so
  # nixpkgs' Darwin skip for git::utils::should_canonicalize no longer
  # matches. The test expects "../" to resolve under /Users/, which fails in
  # the Nix build directory.
  cargo-generate =
    if prev.stdenv.hostPlatform.isDarwin && prev.lib.versionAtLeast prev.cargo-generate.version "0.25"
    then
      prev.cargo-generate.overrideAttrs
        (old: {
          checkFlags = (old.checkFlags or [ ]) ++ [ "--skip=utils::tests::should_canonicalize" ];
        })
    else prev.cargo-generate;
} // prev.lib.packagesFromDirectoryRecursive {
  inherit (final) callPackage;
  directory = ./pkgs;
}))
