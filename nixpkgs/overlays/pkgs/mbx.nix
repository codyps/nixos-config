{ lib, rustPlatform, fetchFromGitHub, pkg-config, git }:

rustPlatform.buildRustPackage rec {
  pname = "mbx";
  version = "1.9.0";

  src = fetchFromGitHub {
    owner = "jdx";
    repo = "mr-boxington";
    tag = "v${version}";
    hash = "sha256-yr5JsgGJJt8LMS7+qjlfoe++uigUTZYPyHrm4Zn3PYI=";
  };

  cargoHash = "sha256-qkoWANkbFqkwW3BP6j16K0EOnYYMly6v9YgFnkuzQvA=";
  nativeBuildInputs = [ pkg-config ];
  nativeCheckInputs = [ git ];
  cargoBuildFlags = [ "-p" "mbx" ];
  # Keep local Intel Mac builds practical while retaining release optimization.
  env.CARGO_PROFILE_RELEASE_LTO = "thin";
  env.CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16";
  cargoCheckType = "debug";
  cargoTestFlags = [ "-p" "mbx" "--lib" ];
  # Nix's rustc does not bundle rust-lld in its sysroot. Runtime toolchains
  # come from Rustup; this test specifically assumes a Rustup-style sysroot.
  checkFlags = [ "--skip=managed_linker::tests::rust_lld_repairs_a_dangling_cached_shim" ];

  meta = {
    description = "Shared, self-pruning build cache for Rust projects";
    homepage = "https://github.com/jdx/mr-boxington";
    license = lib.licenses.mit;
    mainProgram = "mbx";
    platforms = lib.platforms.unix;
  };
}
