{ config, pkgs, lib, ... }:
{
  options.p.nix.buildMachines.ward = lib.mkEnableOption "Use `ward` as a build machine.";

  config = {
    nix = {
      buildMachines = if config.p.nix.buildMachines.ward then [
        {
          hostName = "ward.little-moth.ts.net";
          maxJobs = 8;
          systems = [ "x86_64-linux" "aarch64-linux" ];
          supportedFeatures = [ "kvm" "nixos-test" "big-parallel" ];
          speedFactor = 10;
          sshUser = "nix";
          protocol = "ssh-ng";
          publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUsxN2h1UlFpV2pLc1FKTnljclNkdWRXWE1BaVp3eGJvVXhDUzg1VnVUOHYK";
        }
      ] else [];
      sshServe.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA2gAJB7HLffugJejcMpcSUa64q176A6vpdPLI/fBLp/ root@u3"
      ] ++ (import ../ssh-auth.nix).authorizedKeys;
    };
  };
}
