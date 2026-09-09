{ lib, options, pkgs, ... }:
{
  # Append to the platform defaults and any host-specific caches and keys.
  nix.settings = (import ../flake.nix).nixConfig;
  # Home Manager requires a package to generate and validate nix.conf.
  nix.package = lib.mkIf (options ? home) (lib.mkDefault pkgs.nix);
}
