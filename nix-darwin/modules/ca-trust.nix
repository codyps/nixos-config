{ config, lib, ... }:
{
  imports = [ ../../modules/ca-trust.nix ];
  # Packaged Electron apps do not support all Node CLI flags. Shells and
  # managed coding services receive NODE_OPTIONS through their own setup.
  launchd.user.envVariables = lib.mapAttrs (_: lib.mkDefault)
    (builtins.removeAttrs config.programs.caTrust.environment [ "NODE_OPTIONS" ]);
}
