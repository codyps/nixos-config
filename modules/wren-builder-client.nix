{ config, lib, ... }:
let
  cfg = config.p.nix.buildMachines.wren;
in
{
  options.p.nix.buildMachines.wren = {
    enable = lib.mkEnableOption "Use Wren as a remote Intel Darwin builder";
    sshKey = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nix/keys/wren_ed25519";
      description = "Dedicated client private key; enroll its public key on Wren first.";
    };
    publicHostKey = lib.mkOption {
      type = lib.types.str;
      description = "Verified Wren SSH host public key, base64 encoded as required by nix.buildMachines.";
    };
  };

  config = lib.mkIf cfg.enable {
    nix.distributedBuilds = true;
    nix.buildMachines = [{
      hostName = "wren.little-moth.ts.net";
      sshUser = "nix-ssh";
      protocol = "ssh-ng";
      inherit (cfg) sshKey publicHostKey;
      systems = [ "x86_64-darwin" ];
      maxJobs = 2;
      speedFactor = 10;
      supportedFeatures = [ ];
    }];
  };
}
