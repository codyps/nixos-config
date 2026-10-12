{ lib, callPackage, zpl }:
let
  root = /. + builtins.unsafeDiscardStringContext zpl.outPath;
  workspace = (builtins.fromTOML (builtins.readFile (root + "/Cargo.toml"))).workspace;
in
(callPackage (root + "/nix/package.nix") { }).overrideAttrs {
  # Cargo resolves every workspace member, even when building only the proxy.
  # The upstream source list omits zpl-go/bridge; derive it from the manifest
  # so future workspace additions are included too.
  src = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions (map (path: root + "/${path}")
      ([ "Cargo.toml" "Cargo.lock" "LICENSE" ] ++ workspace.members));
  };
}
