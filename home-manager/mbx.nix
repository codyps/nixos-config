{ config, lib, pkgs, ... }:
let
  cfg = config.programs.mbx;
  dataHome = if pkgs.stdenv.hostPlatform.isDarwin then
    "${config.home.homeDirectory}/Library/Application Support"
  else
    config.xdg.dataHome;
  shimDirectory = "${dataHome}/mbx/bin";
  # doctor compares the launcher byte-for-byte with this upstream constant.
  # Extract it from the selected package's source, without patching its shebang.
  cargoShim = pkgs.runCommand "mbx-cargo-shim" { } ''
    ${pkgs.python3}/bin/python3 - ${cfg.package.src}/crates/mbx/src/cli/setup.rs "$out" <<'PYTHON'
    import pathlib, re, sys
    source = pathlib.Path(sys.argv[1]).read_bytes()
    match = re.search(rb'CARGO_SHIM_LAUNCHER:.*?br#"(.*?)"#;', source, re.S)
    if match is None or not match[1].startswith(b"#!/bin/sh\n"):
        raise SystemExit("mbx upstream Cargo shim format changed")
    pathlib.Path(sys.argv[2]).write_bytes(match[1])
    PYTHON
    chmod +x "$out"
  '';
in
{
  options.programs.mbx = {
    enable = lib.mkEnableOption "mr-boxington caching for Cargo";
    package = lib.mkPackageOption pkgs "mbx" { };
    cargoPackage = lib.mkPackageOption pkgs "rustup" {
      extraDescription = "Provides the underlying Cargo used by both cargo and mbx.";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.cargo-target-cache.enable = lib.mkDefault false;
    assertions = [{
      assertion = !config.programs.cargo-target-cache.enable;
      message = "programs.mbx and programs.cargo-target-cache cannot both wrap Cargo.";
    }];

    home.file."${shimDirectory}/cargo".source = cargoShim;
    home.file."${shimDirectory}/mbx-target".text = "${cfg.package}/bin/mbx\n";
    # Upstream removes this dedicated directory before finding real Cargo.
    # Keep Rustup and other tools in the shared profile, outside that directory.
    home.sessionPath = [ shimDirectory ];
    home.packages = [ cfg.package cfg.cargoPackage ];
  };
}
