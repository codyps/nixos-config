{ lib, options, pkgs, ... }:
let
  ghostty = if pkgs.stdenv.hostPlatform.isDarwin then pkgs.ghostty-bin else pkgs.ghostty;
in
{
  # Support SSH sessions from Ghostty without installing the terminal emulator.
  config = lib.mkMerge [
    (lib.optionalAttrs (options ? environment.systemPackages) {
      environment.systemPackages = [ ghostty.terminfo ];
    })
    (lib.optionalAttrs (options ? home.packages) {
      home.packages = [ ghostty.terminfo ];
    })
  ];
}
