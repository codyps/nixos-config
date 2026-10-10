{ pkgs, ... }:
let
  command = pkgs.writeShellApplication {
    name = "hardware-source";
    runtimeInputs = [ pkgs.python3 pkgs.git pkgs.sops pkgs.gnupg ];
    text = ''
      exec python3 ${../scripts/hardware-identities.py} "$@"
    '';
  };
in
{
  imports = [ ./admin-commands.nix ];
  programs.adminCommands.commands.hardware-source = [ "${command}/bin/hardware-source" ];
}
