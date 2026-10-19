{ pkgs, shimDirectory, package ? pkgs.mbx }:
{
  inherit shimDirectory;
  cargoShim = import ../nixpkgs/mbx-cargo-shim.nix { inherit pkgs package; };
  target = pkgs.writeText "mbx-target" "${package}/bin/mbx\n";
  configFile = ../config/mbx.toml;
  # direnvrc runs before .envrc, so restore shim priority at export time.
  # Mirror direnv's internal EXIT trap, including its dump fd and status.
  direnv = ''
    _mbx_direnv_exit() {
      local status=$?
      local shim=${pkgs.lib.escapeShellArg shimDirectory}
      if [[ -x "$shim/cargo" && ":$PATH:" == *":$shim:"* ]]; then
        PATH_add "$shim"
      fi
      "$direnv" dump json "" >&3
      trap - EXIT
      exit "$status"
    }
    trap _mbx_direnv_exit EXIT
  '';
}
