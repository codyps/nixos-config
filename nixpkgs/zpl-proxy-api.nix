{ lib, callPackage, zpl, pkg-config, aws-lc, openssl, zstd }:
let
  root = /. + builtins.unsafeDiscardStringContext zpl.outPath;
  workspace = (builtins.fromTOML (builtins.readFile (root + "/Cargo.toml"))).workspace;
in
(callPackage (root + "/nix/package.nix") { }).overrideAttrs (old: {
  # Cargo resolves every workspace member, even when building only the proxy.
  # The upstream source list omits zpl-go/bridge; derive it from the manifest
  # so future workspace additions are included too.
  src = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions (map (path: root + "/${path}")
      ([ "Cargo.toml" "Cargo.lock" "LICENSE" ] ++ workspace.members));
  };
  # nixpkgs' cargo setup hook forces system libraries (AWS_LC_SYS_USE_SYSTEM
  # and friends); supply them rather than relying on vendored builds.
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkg-config ];
  buildInputs = (old.buildInputs or [ ]) ++ [ aws-lc openssl zstd ];
})
