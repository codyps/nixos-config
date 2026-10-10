{ config, lib, pkgs, ... }:
let
  cfg = config.boot.secureUnlock;
  setupConfig = pkgs.writeText "secure-unlock.json" (builtins.toJSON {
    disk = config.boot.initrd.luks.devices.${cfg.mapperName}.device;
    hostName = config.networking.hostName;
    inherit (cfg) mapperName stateDirectory rootVolumeKeyId;
    remoteUnlock = cfg.remoteUnlock.enable;
    wifi = cfg.remoteUnlock.wifi.enable;
    tailscale = cfg.remoteUnlock.enable && cfg.remoteUnlock.tailscale.enable;
    tailscaleHostName = cfg.remoteUnlock.tailscale.hostName;
    policy = config.boot.lanzaboote.measuredBoot.pcrlockPolicy;
    diskUnlock = config.boot.secureUnlock.tpmUnlock.enable;
    pcrlock = "${config.systemd.package}/lib/systemd/systemd-pcrlock";
  });
  setup = pkgs.writeShellApplication {
    name = "secure-unlock-setup";
    runtimeInputs = with pkgs; [ python3 config.systemd.package cryptsetup openssh util-linux ]
      ++ lib.optional cfg.remoteUnlock.tailscale.enable pkgs.tailscale
      ++ lib.optional (lib.any (fs: fs.fsType == "zfs") (lib.attrValues config.fileSystems)) config.boot.zfs.package;
    text = ''
      exec python3 ${./tpm-setup.py} --config ${setupConfig} "$@"
    '';
  };
  provision = "${setup}/bin/secure-unlock-setup prepare-install";
in
{
  config = lib.mkIf cfg.enable {
    environment.etc."secure-unlock.json".source = setupConfig;
    environment.systemPackages = [ setup ];
    boot.secureUnlock.provisioningPackage = setup;
    programs.adminCommands.commands = {
      setup-unlock-credentials = [ "${setup}/bin/secure-unlock-setup" "credentials" ];
    } // lib.optionalAttrs cfg.tpmUnlock.enable {
      setup-luks-tpm-unlock = [ "${setup}/bin/secure-unlock-setup" "enroll-disk" ];
    } // lib.optionalAttrs (cfg.remoteUnlock.enable && cfg.remoteUnlock.tailscale.enable) {
      setup-unlock-tailscale = [ "${setup}/bin/secure-unlock-setup" "enroll-tailscale" ];
    };
    systemd.tmpfiles.rules = [ "d ${cfg.stateDirectory} - root root -" ];
    systemd.services.secure-unlock-credentials = {
      description = "Provision persistent TPM-sealed initrd SSH credentials";
      wantedBy = [ "multi-user.target" ];
      wants = [ "tpm2.target" ];
      after = [ "tpm2.target" ];
      unitConfig = {
        RequiresMountsFor = [ cfg.stateDirectory ];
        # Never seal a newly generated key to a disabled Secure Boot policy.
        ConditionSecurity = "uefi-secureboot";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = provision;
        UMask = "0077";
        TimeoutStartSec = "120s";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.stateDirectory "/run" ];
        PrivateTmp = true;
      };
    };
  };
}
