{ lib, ...}: {

  programs.git.signing.signByDefault = lib.mkForce true;
}
