(final: prev: ({
  # Protobuf's Abseil dependency now exposes C++20 comparison types.
  usbguard =
    if prev.usbguard.version == "1.1.4" then
      prev.usbguard.overrideAttrs
        (old: {
          postPatch = (old.postPatch or "") + ''
            substituteInPlace configure.ac --replace-fail '-std=c++17' '-std=c++20'
          '';
        })
    else prev.usbguard;

  # GCC 16 defaults to C++20, where std::lerp conflicts with rxvt's helper.
  rxvt-unicode-unwrapped =
    if prev.rxvt-unicode-unwrapped.version == "9.31" then
      prev.rxvt-unicode-unwrapped.overrideAttrs
        (old: {
          postPatch = (old.postPatch or "") + ''
            substituteInPlace src/rxvtutil.h src/rxvttoolkit.C \
              --replace-fail 'lerp' 'rxvt_lerp'
          '';
        })
    else prev.rxvt-unicode-unwrapped;

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
