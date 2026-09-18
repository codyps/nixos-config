{ config, lib, pkgs, ... }:
let
  helper = pkgs.writeShellApplication {
    name = "warbler-account-passwords";
    runtimeInputs = [ pkgs.mkpasswd pkgs.util-linux ];
    text = ''
      exec ${pkgs.python3}/bin/python3 -I ${./account-passwords.py} "$@"
    '';
  };
  passwordRules = service: {
    # Do not return on pam_unix success: persist its new hash before reporting
    # success. On failure, stop before running the persistence hook.
    unix.control = lib.mkForce "requisite";
    warbler-persist = {
      order = config.security.pam.services.${service}.rules.password.unix.order + 1;
      control = "required";
      modulePath = "${pkgs.pam}/lib/security/pam_exec.so";
      args = [ "seteuid" "${helper}/bin/warbler-account-passwords" "pam-save" ];
    };
  };
in
{
  users.mutableUsers = false;
  users.users.root.hashedPasswordFile = "/persist/shadow.d/root";
  users.users.cody.hashedPasswordFile = "/persist/shadow.d/cody";
  # NixOS normally omits passwd's setuid wrapper with immutable users. Expose
  # just password changes; keep chsh and general account mutation undeclared.
  security.wrappers.passwd = {
    source = "${config.security.loginDefs.package}/bin/passwd";
    owner = "root";
    group = "root";
    setuid = true;
  };
  environment.systemPackages = [ helper ];
  security.pam.services.passwd.rules.password = passwordRules "passwd";
  security.pam.services.chpasswd.rules.password = passwordRules "chpasswd";
}
