{ config, lib, pkgs, ... }:
let
  cfg = config.boot.secureUnlock;
  setupConfig = pkgs.writeText "secure-unlock.json" (builtins.toJSON {
    disk = config.boot.initrd.luks.devices.${cfg.mapperName}.device;
    hostName = config.networking.hostName;
    inherit (cfg) mapperName stateDirectory;
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
      ++ lib.optional cfg.remoteUnlock.tailscale.enable pkgs.tailscale;
    text = ''
      exec python3 ${./tpm-setup.py} --config ${setupConfig} "$@"
    '';
  };
  provision = "${setup}/bin/secure-unlock-setup credentials"
    + lib.optionalString (!config.boot.secureUnlock.remoteUnlock.wifi.enable) " --ssh-only";
in
{
  # A normal activation script runs too late: switch installs boot files first.
  # Wrap the existing external-loader hook without replacing Lanzaboote logic.
  options.boot.loader.external.installHook = lib.mkOption {
    apply = original:
      if cfg.enable && cfg.remoteUnlock.enable then
        pkgs.writeShellScript "secure-unlock-provision-and-install-bootloader" ''
          set -eu
          ${provision}
          exec ${original} "$@"
        ''
      else original;
  };

  config = lib.mkIf cfg.enable {
    environment.etc."secure-unlock.json".source = setupConfig;
    environment.systemPackages = [ setup ];
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
