{ config, options, pkgs, lib, ... }:
{
  options.p.nix.buildMachines.ward.enable = lib.mkEnableOption "Use `ward` as a build machine.";
  options.p.nix.buildMachines.ward.sshKey = lib.mkOption {
    type = lib.types.path;
    default = "";
    description = ''
      Path to the SSH private key to use for authenticating to the `ward` build machine.
    '';
  };

  options.p.nix.settings.substituters.ward = lib.mkEnableOption "Use `ward` as a substituter.";

  config = {
    nix = {
      settings = {
        substituters =
          if config.p.nix.settings.substituters.ward then
            [ "https://ward.little-moth.ts.net/nix-cache" ] ++ (if hostname != "ward" then [ "https://ward.little-moth.ts.net/harmonia" ] else [ ])
          else
            [ ];
      };

      buildMachines =
        if config.p.nix.buildMachines.ward.enable then [
          {
            hostName = "ward.little-moth.ts.net";
            maxJobs = 8;
            systems = [ "x86_64-linux" "aarch64-linux" ];
            supportedFeatures = [ "kvm" "nixos-test" "big-parallel" ];
            speedFactor = 10;
            sshUser = "nix";
            protocol = "ssh-ng";
            publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUsxN2h1UlFpV2pLc1FKTnljclNkdWRXWE1BaVp3eGJvVXhDUzg1VnVUOHYK";
            sshKey = if config.p.nix.buildMachines.ward.sshKey != "" then config.p.nix.buildMachines.ward.sshKey else null;
          }
        ] else [ ];

    } // (if options.nix ? sshServe then {
      # darwin doesn't have this, nixos only.
      # TODO: find a nicer way to check.
      sshServe.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA2gAJB7HLffugJejcMpcSUa64q176A6vpdPLI/fBLp/ root@u3"
      ] ++ (import ../nixos/ssh-auth.nix).authorizedKeys;
    } else { });
  };


}
