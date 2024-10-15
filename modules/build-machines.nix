{ config, pkgs, ... }:

{
  options = {
    nixBuildMachines = {
      ward = lib.mkEnableOption "Use `ward` as a build machine.";
    };
  };

  config = {
    nix = {
      buildMachines = if config.nixBuildMachines.ward then [
        {
          hostName = "ward.little-moth.ts.net";
          maxJobs = 8;
          supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
          supportedFeatures = [ "kvm" "nixos-test" "big-parallel" ];
          speedFactor = 10;
          sshUser = "nix";
          sshKey = "/persist/etc/nix-ssh/id_rsa";
          publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUsxN2h1UlFpV2pLc1FKTnljclNkdWRXWE1BaVp3eGJvVXhDUzg1VnVUOHYK";
        }
      ] else [];
    };
  };
}
