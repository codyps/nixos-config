{ config, pkgs, ... }:
{
  home.packages = with pkgs; [
    lima
    ctlptl
    tilt
  ];
}
