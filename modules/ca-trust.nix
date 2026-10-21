{ config, lib, pkgs, ... }:
let
  cfg = config.programs.caTrust;
  trust = import ../lib/ca-trust.nix { inherit pkgs; bundle = cfg.bundle; };
in
{
  options.programs.caTrust = {
    bundle = lib.mkOption {
      type = lib.types.path;
      default = config.environment.etc."ssl/certs/ca-certificates.crt".source;
      description = "Nix-managed CA bundle shared by configurable TLS clients.";
    };
    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = trust.environment;
      description = "CA settings for managed services and their child processes.";
    };
  };

  config = {
    security.pki.caCertificateBlacklist = trust.blacklist;
    environment.variables = trust.environment;
  };
}
