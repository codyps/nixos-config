{ config, lib, pkgs, ... }:
let
  user = "cody-ai";
  home = config.users.users.${user}.home;
  mbx = import ../../lib/mbx.nix { inherit pkgs; shimDirectory = "${home}/.local/share/mbx/bin"; };
in
{
  imports = [ ../codex-config.nix ];

  # These accounts use NixOS activation rather than Home Manager.
  programs.codex-config = {
    users = [ user ];
    updateExisting = true;
  };

  users.users.${user}.packages = [ pkgs.tmux pkgs.mbx pkgs.rustup ];
  # Both the legacy host account and container use this setup. Login shells
  # need the shim even when their inherited session variables are stale.
  environment.extraInit = ''
    if [ "''${USER-}" = ${lib.escapeShellArg user} ]; then
      export PATH=${lib.escapeShellArg mbx.shimDirectory}:"$PATH"
    fi
  '';
  programs.direnv.direnvrcExtra = lib.mkAfter mbx.direnv;
  systemd.tmpfiles.rules = [
    "L+ ${home}/.tmux.conf - ${user} ${user} - ${../../config/.tmux.conf}"
    "d ${home}/.config 0755 ${user} ${user} -"
    "d ${home}/.config/mbx 0755 ${user} ${user} -"
    "L+ ${home}/.config/mbx/config.toml - ${user} ${user} - ${mbx.configFile}"
    "d ${home}/.local 0755 ${user} ${user} -"
    "d ${home}/.local/share 0755 ${user} ${user} -"
    "d ${home}/.local/share/mbx 0755 ${user} ${user} -"
    "d ${mbx.shimDirectory} 0755 ${user} ${user} -"
    "L+ ${mbx.shimDirectory}/cargo - ${user} ${user} - ${mbx.cargoShim}"
    "L+ ${mbx.shimDirectory}/mbx-target - ${user} ${user} - ${mbx.target}"
  ];
}
