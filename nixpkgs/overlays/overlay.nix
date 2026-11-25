(final: prev: ({
  gh = import ../gh-with-attribution-check.nix { pkgs = final; gh = prev.gh; };

  # nix-update 1.16.0 fails on dirty flakes with current Nix because
  # `nix flake metadata` no longer copies the tree to the store. 1.17.0 uses
  # `nix flake prefetch` instead, so tracked package updates can rewrite the
  # version before fetching hashes.
  nix-update =
    if prev.lib.versionOlder prev.nix-update.version "1.17.0" then
      prev.nix-update.overridePythonAttrs
        (_: {
          version = "1.17.0";
          src = prev.fetchFromGitHub {
            owner = "Mic92";
            repo = "nix-update";
            tag = "v1.17.0";
            hash = "sha256-TCOhUWb53V3nrJRD3JuADly1U9fNi0Z79QMcjhbefHg=";
          };
          build-system = [ prev.python3Packages.hatchling ];
          dependencies = [ prev.python3Packages.ast-grep-py ];
        })
    else prev.nix-update;

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

  # ccache 4.14.2 lists Linux-only elfutils (for eu-elfcmp) as an
  # unconditional check input, so Darwin evaluation is refused. Its base and
  # fprebuilt_module_path suites also fail on Darwin because the clang wrapper
  # emits unused-argument warnings the tests treat as unexpected stderr.
  # Skip the check phase on Darwin, which also drops the check inputs.
  ccache =
    if prev.stdenv.hostPlatform.isDarwin && prev.ccache.version == "4.14.2"
    then prev.ccache.overrideAttrs (_: { doCheck = false; })
    else prev.ccache;

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

  # The OpenCode server rejects clients newer than itself, so the servers on
  # crow (host and crow-ai container) and the home-manager CLI installs must
  # not trail upstream releases. Track the newest tag (nixpkgs/opencode.nix)
  # until the nixpkgs pins catch up. Upstream nixpkgs dropped x86_64-darwin
  # from meta.platforms because Bun errors on pre-AVX Intel Macs; every
  # managed Intel Darwin host (and the macos-15-intel CI runners) has AVX2,
  # so the tracked expression keeps building the current tag there too.
  opencode =
    let
      tracked = final.callPackage ../opencode.nix { };
    in
    if prev.lib.versionOlder prev.opencode.version tracked.version then tracked else prev.opencode;
} // prev.lib.packagesFromDirectoryRecursive {
  inherit (final) callPackage;
  directory = ./pkgs;
}))
