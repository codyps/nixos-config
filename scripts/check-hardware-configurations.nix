# Public builds use stable device aliases and require local state only at install.
{ flake }:
let
  lib = flake.inputs.nixpkgs.lib;
  hosts = builtins.filter (host: host.config.services.hardwareIdentities.enable) (builtins.attrValues flake.nixosConfigurations);
  secure = map (name: flake.nixosConfigurations.${name}.config) [ "crow" "ward" "warbler" ];
in
assert !(flake.inputs ? hardware-identities);
assert builtins.all (host: !host.config.services.hardwareIdentities.allowFixtures && host.config.system.preSwitchChecks ? hardware-identities) hosts;
assert builtins.all (c: c.boot.secureUnlock.rootVolumeKeyIdFile != null && c.boot.lanzaboote.enable && c.boot.lanzaboote.measuredBoot.enable) secure;
assert lib.hasPrefix "/dev/disk/by-hardware/" flake.nixosConfigurations.ward.config.boot.initrd.luks.devices.luksroot.device;
assert lib.hasPrefix "/dev/disk/by-hardware/" flake.nixosConfigurations.mifflin.config.fileSystems."/".device;
assert flake.nixosConfigurations.crow.config.system.build.initialRamdiskSecretAppender.name == "append-initrd-secrets";
{ machineLocalIdentities = true; signedInitrdPersonalization = true; directRepositoryBuilds = true; }
