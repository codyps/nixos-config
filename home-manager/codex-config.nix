{ config, lib, pkgs, ... }:
let
  configure = import ../nixpkgs/codex-configure.nix { inherit pkgs; };
  cacheHome =
    if pkgs.stdenv.hostPlatform.isDarwin
    then "${config.home.homeDirectory}/Library/Caches"
    else config.xdg.cacheHome;
in
{
  home.packages = [ configure ];
  # Keep the live file out of home.file: Codex owns and edits it after seeding.
  home.activation.seedCodexConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${configure}/bin/codex-configure --if-missing \
      --config ${lib.escapeShellArg "${config.home.homeDirectory}/.codex/config.toml"} \
      --cache-home ${lib.escapeShellArg cacheHome}
  '';
}
