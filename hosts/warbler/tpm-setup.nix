{ config, lib, pkgs, ... }:
let
  setup = pkgs.writeShellApplication {
    name = "warbler-tpm-setup";
    runtimeInputs = with pkgs; [ python3 systemd cryptsetup openssh util-linux ];
    text = ''
      exec python3 ${./tpm-setup.py} "$@"
    '';
  };
  provision = "${setup}/bin/warbler-tpm-setup credentials"
    + lib.optionalString (!config.warbler.remoteUnlock.wifi.enable) " --ssh-only";
in
{
  # A normal activation script runs too late: switch installs boot files first.
  # Wrap the existing external-loader hook without replacing Lanzaboote logic.
  options.boot.loader.external.installHook = lib.mkOption {
    apply = original:
      if config.warbler.remoteUnlock.enable then
        pkgs.writeShellScript "warbler-provision-and-install-bootloader" ''
          set -eu
          ${provision}
          exec ${original} "$@"
        ''
      else original;
  };

  config = {
    environment.etc."warbler-tpm.json".text = builtins.toJSON {
      disk = "/dev/disk/by-partlabel/disk-system-crypt";
      policy = config.boot.lanzaboote.measuredBoot.pcrlockPolicy;
      diskUnlock = config.warbler.tpmUnlock.enable;
      pcrlock = "${config.systemd.package}/lib/systemd/systemd-pcrlock";
    };
    environment.systemPackages = [ setup ];
    systemd.services.warbler-initrd-credentials = {
      description = "Provision persistent TPM-sealed initrd SSH credentials";
      wantedBy = [ "multi-user.target" ];
      wants = [ "tpm2.target" ];
      after = [ "tpm2.target" ];
      unitConfig = {
        RequiresMountsFor = [ "/persist" ];
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
        ReadWritePaths = [ "/persist" "/run" ];
        PrivateTmp = true;
      };
    };
  };
}
