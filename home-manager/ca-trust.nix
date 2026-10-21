{ lib, pkgs, ... }@args:
let
  # Integrated homes share the host's bundle, including local trust additions.
  # Standalone homes receive a filtered bundle from their own pinned package set.
  trust = import ../lib/ca-trust.nix {
    inherit pkgs;
    bundle = if args ? osConfig then args.osConfig.programs.caTrust.bundle else null;
  };
  defaults = lib.mapAttrs (_: lib.mkDefault) trust.environment;
in
{
  home.sessionVariables = defaults;
  # Home Manager writes these values verbatim to environment.d. Preserve the
  # inner ERTS quoting when systemd parses that file.
  systemd.user.sessionVariables = lib.mkIf pkgs.stdenv.hostPlatform.isLinux
    (lib.mapAttrs (_: value: lib.mkDefault (builtins.toJSON value))
      (builtins.removeAttrs trust.environment [ "NODE_OPTIONS" ]));
}
