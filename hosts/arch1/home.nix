{ lib, ...}: {

  imports = [
    ../../home-manager/arch-autoupdate.nix
  ];

  programs.git.signing = {
    key = lib.mkForce "B102AB40FD24F9B69C940D70A2105F1C721A5C52";
    signByDefault = lib.mkForce false;
  };
}
