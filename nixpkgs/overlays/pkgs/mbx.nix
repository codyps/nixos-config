{ lib, stdenv, rustPlatform, fetchFromGitHub, pkg-config, git, cacert, aws-lc, openssl, zstd, coreutils }:

rustPlatform.buildRustPackage rec {
  pname = "mbx";
  version = "1.31.0";

  src = fetchFromGitHub {
    owner = "jdx";
    repo = "mr-boxington";
    tag = "v${version}";
    hash = "sha256-82Sr5wxviQm21QonS5I/OyShjWXG+H1+XjDJiRfS1H4=";
  };

  cargoHash = "sha256-MAVmW8Ngo5szLaHw8M8HKfkgBMrphux/wfHAtbU0AOs=";
  postPatch = lib.optionalString stdenv.hostPlatform.isLinux ''
    substituteInPlace crates/mbx/src/target_lease_tests.rs \
      --replace-fail '"/bin/sleep", "/usr/bin/sleep"' '"${lib.getExe' coreutils "sleep"}"'
  '';
  nativeBuildInputs = [ pkg-config ];
  # nixpkgs' cargo setup hook now forces system libraries: zstd-sys probes
  # pkg-config instead of falling back, openssl-sys refuses to vendor, and
  # aws-lc-sys requires a system AWS-LC. Supply each crate's library.
  buildInputs = [ aws-lc openssl zstd ];
  nativeCheckInputs = [ git ];
  cargoBuildFlags = [ "-p" "mbx" ];
  # Keep local Intel Mac builds practical while retaining release optimization.
  env.CARGO_PROFILE_RELEASE_LTO = "thin";
  env.CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16";
  cargoCheckType = "debug";
  cargoTestFlags = [ "-p" "mbx" "--lib" ];
  # S3 client tests load native TLS roots even without making network requests.
  preCheck = ''
    export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
  '';
  # Nix's rustc does not bundle rust-lld in its sysroot. Runtime toolchains
  # come from Rustup; this test specifically assumes a Rustup-style sysroot.
  checkFlags = [
    "--skip=managed_linker::tests::rust_lld_repairs_a_dangling_cached_shim"
    # Spawning the test's shell through the PTY fails in the Nix build sandbox.
    "--skip=cli::pretty::tests::pty_child_inherits_the_seeded_environment_not_the_registry"
  ];

  meta = {
    description = "Shared, self-pruning build cache for Rust projects";
    homepage = "https://github.com/jdx/mr-boxington";
    license = lib.licenses.mit;
    mainProgram = "mbx";
    platforms = lib.platforms.unix;
  };
}
