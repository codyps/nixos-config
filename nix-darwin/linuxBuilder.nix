# https://discourse.nixos.org/t/nixpkgs-support-for-linux-builders-running-on-macos/24313
# https://nixos.org/manual/nixpkgs/unstable/#sec-darwin-builder
{ config, pkgs, lib, ... }:
let
  dataDir = "/var/lib/nixos-builder";
  linuxSystem = builtins.replaceStrings [ "darwin" ] [ "linux" ]
    pkgs.stdenv.hostPlatform.system;

  darwin-builder = (import "${pkgs.path}/nixos" {
    system = linuxSystem;
    configuration = ({ modulesPath, lib, ... }: {
      imports = [ "${modulesPath}/profiles/macos-builder.nix" ];
      virtualisation = {
        # FIXME: this _appears_ to result in using our modified (overlayed)
        # nixpkgs, which then forces a rebuild, which requires we have a
        # running linux builder. Non-ideal. Need to find a way to get the
        # non-overlayed nixpkgs.
        host.pkgs = pkgs;
        darwin-builder.workingDirectory = dataDir;
      };
    });
  }).config.system.build.macos-builder-installer;
in
{
  config = {
    # Enable remote builds
    nix.distributedBuilds = true;

    nix.buildMachines = [{
      hostName = "linux-builder";
      system = linuxSystem;
      maxJobs = 4;
      supportedFeatures = [ "kvm" "benchmark" "big-parallel" ];
      protocol = "ssh-ng";
    }];

    environment.etc."nix/ssh_known_hosts.d/linux-builder".text = ''
      [127.0.0.1]:31022 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJBWcxb/Blaqt1auOtE+F8QUWrUotiC5qBJ+UuEWdVCb
    '';

    # We can't/want to edit /var/root/.ssh/config so instead we create the config at another location and tell ssh to use that instead by modifying NIX_SSHOPTS
    environment.etc."nix/ssh_config".text = ''
      Include /etc/nix/ssh_config.d/*
    '';

    environment.etc."nix/ssh_config.d/linux-builder".text = ''
      Host linux-builder
        User builder
        HostName 127.0.0.1
        Port 31022
        IdentityFile ${dataDir}/keys/builder_ed25519
        UserKnownHostsFile /etc/nix/ssh_known_hosts.d/linux-builder
    '';

    # Tell nix-daemon to use our custom SSH config
    nix.envVars = { NIX_SSHOPTS = "-F /etc/nix/ssh_config"; };

    launchd.daemons.linux-builder = {
      command = "${darwin-builder}/bin/create-builder";
      serviceConfig = {
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "/var/log/linux-builder.log";
        StandardErrorPath = "/var/log/linux-builder.log";
      };
    };
  };
}
