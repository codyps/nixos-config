{ lib, pkgs, osConfig ? null, ... }:
{
  # System modules supply the same rules for integrated NixOS/Darwin homes.
  config = lib.mkIf (osConfig == null) {
    home.file.".ssh/config.d/gpg-agent-forwarding".text =
      import ../lib/gpg-agent-forwarding.nix { inherit lib pkgs; };
  };
}
