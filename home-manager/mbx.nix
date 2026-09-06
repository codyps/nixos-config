{ config, lib, pkgs, ... }:
let
  cfg = config.programs.mbx;
  cargo = pkgs.writeShellScriptBin "cargo" ''
    export CARGO=${cfg.cargoPackage}/bin/cargo
    export MBX_CARGO_SHIM_MODE=1
    unset MBX_CARGO_SHIM_PATH
    exec ${cfg.package}/bin/mbx "$@"
  '';
  mbx = pkgs.writeShellScriptBin "mbx" ''
    export CARGO=${cfg.cargoPackage}/bin/cargo
    unset MBX_CARGO_SHIM_MODE MBX_CARGO_SHIM_PATH
    exec ${cfg.package}/bin/mbx "$@"
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

    # Use upstream's shim-mode dispatch (also used by mise). Pin the real
    # Cargo instead of removing the shim's directory from PATH: Home Manager
    # merges cargo with other tools in one bin directory. Explicit mbx commands
    # need the same real Cargo to avoid rediscovering our cargo launcher.
    home.packages = [
      (lib.hiPrio cargo)
      mbx
      cfg.cargoPackage
    ];
  };
}
