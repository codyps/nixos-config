# nix eval --impure --json --option eval-cache false --file scripts/test-nix-dynamic-machines-modules.nix
let
  flake = builtins.getFlake (toString ../.);
  lib = flake.inputs.nixpkgs.lib;
  example = {
    services.nix-dynamic-machines = {
      enable = true;
      alwaysBuilders = [ "ssh-ng://root@docker x86_64-linux - 4 20" ];
      probeBuilders = [ "ssh-ng://nix@remote x86_64-linux /run/secrets/key 8 10" ];
      healthyInterval = 90;
      retryInterval = 20;
      maxRetryInterval = 160;
      parallelism = 3;
    };
    nix.buildMachines = [{
      hostName = "static-builder";
      system = "x86_64-linux";
      protocol = "ssh-ng";
    }];
  };
  linux = extra: (flake.inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      flake.nixosModules.nix-dynamic-machines
      {
        system.stateVersion = "26.05";
        fileSystems."/" = { device = "/dev/root"; fsType = "ext4"; };
        boot.loader.grub.enable = false;
      }
      extra
    ];
  }).config;
  darwin = input: system: extra: (input.lib.darwinSystem {
    inherit system;
    modules = [
      flake.darwinModules.nix-dynamic-machines
      {
        system.stateVersion = 6;
        nixpkgs.config.allowDeprecatedx86_64Darwin = "force";
      }
      extra
    ];
  }).config;
  l = linux example;
  d = darwin flake.inputs.nix-darwin-26-05 "x86_64-darwin" example;
  a = darwin flake.inputs.nix-darwin "aarch64-darwin" example;
  offLinux = linux { };
  dynamicOnly = linux { services.nix-dynamic-machines.enable = true; };
  offDarwin = darwin flake.inputs.nix-darwin-26-05 "x86_64-darwin" { };
  invalid = linux {
    services.nix-dynamic-machines = {
      enable = true;
      retryInterval = 20;
      maxRetryInterval = 10;
    };
  };
  check = condition: message: if condition then true else throw message;
  service = l.systemd.services.nix-dynamic-machines;
  daemon = d.launchd.daemons.nix-dynamic-machines;
in
assert check (builtins.all (x: x.assertion) l.assertions) "NixOS assertions failed";
assert check (builtins.all (x: x.assertion) d.assertions) "Darwin assertions failed";
assert check (builtins.all (x: x.assertion) a.assertions) "ARM Darwin assertions failed";
assert check (l.nix.settings.builders == "@/etc/nix/machines; @/var/lib/nix-dynamic-machines/machines") "NixOS dropped static builders";
assert check (d.nix.settings.builders == "@/etc/nix/machines; @/var/db/nix-dynamic-machines/machines") "Darwin dropped static builders";
assert check (dynamicOnly.nix.settings.builders == "@/var/lib/nix-dynamic-machines/machines") "Referenced a nonexistent static machines file";
assert check (service.serviceConfig.Restart == "on-failure" && service.serviceConfig.KillMode == "mixed") "NixOS supervision changed";
assert check (daemon.serviceConfig.KeepAlive && daemon.serviceConfig.RunAtLoad) "Darwin supervision changed";
assert check (!(offLinux.systemd.services ? nix-dynamic-machines)) "Disabled NixOS service exists";
assert check (!(offDarwin.launchd.daemons ? nix-dynamic-machines)) "Disabled Darwin daemon exists";
assert check (builtins.any (x: !x.assertion && lib.hasInfix "retryInterval" x.message) invalid.assertions) "Invalid retry intervals accepted";
{
  passed = true;
  linuxUnit = l.systemd.units."nix-dynamic-machines.service".unit;
  linuxUnitText = l.systemd.units."nix-dynamic-machines.service".text;
  darwinPlist = d.environment.launchDaemons."org.nixos.nix-dynamic-machines.plist".source;
  darwinRunner = builtins.head daemon.serviceConfig.ProgramArguments;
  armDarwinRunner = builtins.head a.launchd.daemons.nix-dynamic-machines.serviceConfig.ProgramArguments;
  darwinBuilders = d.nix.settings.builders;
}
