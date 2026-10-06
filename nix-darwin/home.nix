{ config, pkgs, ... }:
{
  # Home Manager's Darwin session startup searches the user profile for terminfo.
  imports = [ ../modules/terminfo.nix ];

  home.packages = with pkgs; [
    lima
    ctlptl
    tilt
  ];
}
