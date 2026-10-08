{ config, lib, pkgs, ... }:
let
  cfg = config.programs.mbx;
  dataHome =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "${config.home.homeDirectory}/Library/Application Support"
    else
      config.xdg.dataHome;
  shimDirectory = "${dataHome}/mbx/bin";
  cargoShim = import ../nixpkgs/mbx-cargo-shim.nix { inherit pkgs; package = cfg.package; };
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
    home.file."${shimDirectory}/cargo".source = cargoShim;
    home.file."${shimDirectory}/mbx-target".text = "${cfg.package}/bin/mbx\n";
    # Upstream removes this dedicated directory before finding real Cargo.
    # Keep Rustup and other tools in the shared profile, outside that directory.
    home.sessionPath = [ shimDirectory ];
    home.packages = [ cfg.package cfg.cargoPackage ];

    programs.direnv.stdlib = lib.mkAfter ''
      # direnvrc runs before .envrc, so restore shim priority at export time.
      # This mirrors direnv's internal EXIT trap, including its dump fd/status.
      _mbx_direnv_exit() {
        local status=$?
        local shim=${lib.escapeShellArg shimDirectory}
        if [[ -x "$shim/cargo" && ":$PATH:" == *":$shim:"* ]]; then
          PATH_add "$shim"
        fi
        "$direnv" dump json "" >&3
        trap - EXIT
        exit "$status"
      }
      trap _mbx_direnv_exit EXIT
    '';
  };
}
