{ config, pkgs, ... }:
{
  home.packages = with pkgs; [
    vscode
    lima
    ctlptl
    tilt
  ];
}
