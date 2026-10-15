{ config, lib, pkgs, ... }:
let
  personalHost = !builtins.elem config.networking.hostName [ "maclay" "trunix" "RVW-LYY7YT7329M" ];
in
{
  config = lib.mkIf personalHost {
    programs.ssh.extraConfig = import ../lib/gpg-agent-forwarding.nix { inherit lib pkgs; };
  };
}
