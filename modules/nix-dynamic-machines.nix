{ config, lib, pkgs, ... }:
let
  cfg = config.services.nix-dynamic-machines;
  interval = default: description: lib.mkOption {
    type = lib.types.ints.between 1 86400;
    inherit default description;
  };
  machineLine = lib.types.addCheck lib.types.singleLineStr
    (line: line != "" && !(lib.hasInfix ";" line));
in
{
  options.services.nix-dynamic-machines = {
    enable = lib.mkEnableOption "the internally scheduled dynamic Nix builder watcher";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../nixpkgs/overlays/pkgs/nix-dynamic-machines.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./nixpkgs/overlays/pkgs/nix-dynamic-machines.nix { }";
      description = "Watcher package. No repository overlay is required.";
    };
    alwaysBuilders = lib.mkOption {
      type = lib.types.listOf machineLine;
      default = [ ];
      example = [ "ssh-ng://root@docker-linux-builder x86_64-linux - 4 20" ];
      description = ''
        Legacy Nix machine lines to include without probing, including on-demand
        activation proxies. Existing nix.buildMachines entries also remain
        available without probing. Use runtime key paths, never private key contents.
      '';
    };
    probeBuilders = lib.mkOption {
      type = lib.types.listOf machineLine;
      default = [ ];
      example = [ "ssh-ng://nix@remote x86_64-linux /run/secrets/builder-key 8 10" ];
      description = ''
        Legacy Nix machine lines whose availability should be probed. Do not also
        put these machines in nix.buildMachines: those entries are unconditional.
        Lines are stored publicly in the Nix store; private keys must stay in
        runtime files. Only ssh and ssh-ng builders are supported.
      '';
    };
    timeout = interval 3 "Maximum seconds per probe.";
    parallelism = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
      description = "Maximum concurrent probes.";
    };
    healthyInterval = interval 60 "Seconds before rechecking a healthy builder.";
    retryInterval = interval 15 "Seconds before the first retry of an unavailable builder.";
    maxRetryInterval = interval 120 "Maximum exponential retry delay in seconds.";
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = cfg.retryInterval <= cfg.maxRetryInterval;
      message = "services.nix-dynamic-machines.retryInterval must not exceed maxRetryInterval.";
    }
      {
        assertion = config.nix.enable;
        message = "services.nix-dynamic-machines requires nix.enable to manage the builders setting.";
      }];
    nix.distributedBuilds = true;
    nix.settings.experimental-features = [ "nix-command" ];
  };
}
