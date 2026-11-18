{ lib, pkgs, ... }@args:
let
  # Integrated homes share the host's bundle, including local trust additions.
  # Standalone homes receive a filtered bundle from their own pinned package set.
  trust = import ../lib/ca-trust.nix {
    inherit pkgs;
    bundle = if args ? osConfig then args.osConfig.programs.caTrust.bundle else null;
    runtimeBundle = if args ? osConfig then args.osConfig.programs.caTrust.environment.SSL_CERT_FILE else null;
  };
  defaults = lib.mapAttrs (_: lib.mkDefault) trust.environment;
in
{
  home.sessionVariables = defaults;
  # Home Manager writes these values verbatim to environment.d. Quote values
  # containing spaces, such as JAVA_TOOL_OPTIONS, for systemd's parser.
  systemd.user.sessionVariables = lib.mkIf pkgs.stdenv.hostPlatform.isLinux
    (lib.mapAttrs (_: value: lib.mkDefault (builtins.toJSON value))
      (builtins.removeAttrs trust.environment [ "NODE_OPTIONS" ]));
}
