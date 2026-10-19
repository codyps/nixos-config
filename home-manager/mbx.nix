{ config, lib, pkgs, ... }:
let
  cfg = config.programs.mbx;
  dataHome =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "${config.home.homeDirectory}/Library/Application Support"
    else
      config.xdg.dataHome;
  shimDirectory = "${dataHome}/mbx/bin";
  mbx = import ../lib/mbx.nix { inherit pkgs shimDirectory; package = cfg.package; };
  configHome = if pkgs.stdenv.hostPlatform.isDarwin then dataHome else config.xdg.configHome;
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
    home.file."${shimDirectory}/cargo".source = mbx.cargoShim;
    home.file."${shimDirectory}/mbx-target".source = mbx.target;
    home.file."${configHome}/mbx/config.toml".source = mbx.configFile;
    # Upstream removes this dedicated directory before finding real Cargo.
    # Keep Rustup and other tools in the shared profile, outside that directory.
    home.sessionPath = [ shimDirectory ];
    home.packages = [ cfg.package cfg.cargoPackage ];

    programs.direnv.stdlib = lib.mkAfter mbx.direnv;
  };
}
