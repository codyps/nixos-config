{ lib, options, pkgs, ... }:
{
  # Support SSH sessions from Ghostty without installing the terminal emulator.
  config = lib.mkMerge [
    (lib.optionalAttrs (options ? environment.systemPackages) {
      environment.systemPackages = [ pkgs.ghostty.terminfo ];
    })
    (lib.optionalAttrs (options ? home.packages) {
      home.packages = [ pkgs.ghostty.terminfo ];
    })
  ];
}
