{ config, lib, ... }:
let
  # GUI services may be packaged Electron apps, which reject Node CLI flags.
  environment = lib.mapAttrs (_: lib.mkDefault)
    (builtins.removeAttrs config.programs.caTrust.environment [ "NODE_OPTIONS" ]);
in
{
  imports = [ ../modules/ca-trust.nix ];
  # pam_env cannot represent embedded double quotes in the Erlang string term.
  # Keep these flags in environment.variables (shells) and systemd instead.
  environment.sessionVariables = builtins.removeAttrs environment [ "ERL_AFLAGS" "ERL_ZFLAGS" ];
  systemd.globalEnvironment = environment;
}
