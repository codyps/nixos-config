(final: prev: ({
  # The frozen Gen8/9/11 runtime predates GCC 16's incomplete-type SFINAE
  # diagnostic and treats it as an error. Keep this legacy package on GCC 15.
  intel-compute-runtime-legacy1 =
    if prev.intel-compute-runtime-legacy1.version == "24.35.30872.41" then
      prev.intel-compute-runtime-legacy1.override { stdenv = prev.gcc15Stdenv; }
    else prev.intel-compute-runtime-legacy1;

  # Contour uses the experimental SIMD API, not GCC 16's new <simd> API.
  # Keep its existing <experimental/simd> branch until upstream migrates.
  contour =
    if prev.contour.version == "0.6.3.8249" then
      prev.contour.overrideAttrs
        (old: {
          postPatch = (old.postPatch or "") + ''
            substituteInPlace src/vtbackend/Image.cpp \
              --replace-fail '#if __has_include(<simd>)' '#if 0'
          '';
        })
    else prev.contour;

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
