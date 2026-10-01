{ config, pkgs, ... }:
let
  user = "cody-ai";
  home = config.users.users.${user}.home;
in
{
  imports = [ ../../nixos-modules/codex-config.nix ];

  # These accounts use NixOS activation rather than Home Manager.
  programs.codex-config = {
    users = [ user ];
    updateExisting = true;
  };

  users.users.${user}.packages = [ pkgs.tmux ];
  systemd.tmpfiles.rules = [
    "L+ ${home}/.tmux.conf - ${user} ${user} - ${../../config/.tmux.conf}"
  ];
}
