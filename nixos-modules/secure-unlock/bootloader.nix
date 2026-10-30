{ config, lib, pkgs, ... }:
let
  cfg = config.boot.secureUnlock;
  lz = config.boot.lanzaboote;
  measured = lz.measuredBoot;
  ready = "${cfg.stateDirectory}/provisioning-ready";
  makePolicy = "${cfg.provisioningPackage}/bin/secure-unlock-setup update-policy";
  # Keep Lanzaboote's installer, signing and generation pruning. Only the timing
  # of measured-boot operations differs from its unconditional install hook.
  install = esp: ''
    ${lz.installCommand} ${lib.escapeShellArgs (
      [ "--public-key=${toString lz.publicKeyFile}" "--private-key=${toString lz.privateKeyFile}" ]
      ++ lib.optional (lz.protectedSystem != null) "--protected-system=${lz.protectedSystem}"
    )} "''${measurement_args[@]}" ${lib.escapeShellArg esp} /nix/var/nix/profiles/system-*-link
    ${cfg.provisioningPackage}/bin/secure-unlock-setup publish-credentials --esp ${lib.escapeShellArg esp}
  '';
in
{
  options.boot.lanzaboote.package = lib.mkOption {
    apply = package:
      if cfg.enable && config.services.hardwareIdentities.enable then
        package.overrideAttrs
          (old: {
            patches = (old.patches or [ ]) ++ [ ./patches/refresh-local-initrd.patch ];
          })
      else package;
  };
  config = lib.mkIf cfg.enable {
    boot.loader.external.installHook = lib.mkForce (pkgs.writeShellScript "secure-unlock-install-bootloader" ''
      set -euo pipefail
      export PATH=${config.systemd.package}/lib/systemd:$PATH
      ${cfg.provisioningPackage}/bin/secure-unlock-setup prepare-install
      measurement_args=()
      ${lib.optionalString (measured.enable && builtins.elem 4 measured.pcrs) ''
        if test -e ${lib.escapeShellArg ready}; then
          ${cfg.provisioningPackage}/bin/secure-unlock-setup retain-booted-measurement
          measurement_args+=(--pcrlock-directory=${lib.escapeShellArg measured.pcrlockDirectory})
        fi
      ''}
      ${lib.optionalString measured.enable ''
        if test -e ${lib.escapeShellArg ready}; then
          # A first rebuild may run from an older console-only generation whose
          # systemd measurement units have never run. Prepare their inputs now.
          ${lib.concatMapStringsSep "\n" (command: "${config.systemd.package}/lib/systemd/systemd-pcrlock ${command}") (
            lib.optionals (builtins.elem 0 measured.pcrs || builtins.elem 2 measured.pcrs) [ "lock-firmware-code" ]
            ++ lib.optionals (builtins.elem 1 measured.pcrs || builtins.elem 3 measured.pcrs) [ "lock-firmware-config" ]
            ++ lib.optionals (builtins.elem 7 measured.pcrs) [ "lock-secureboot-policy" "lock-secureboot-authority" ]
          )}
        fi
      ''}
      ${lib.concatMapStringsSep "\n" install ([ config.boot.loader.efi.efiSysMountPoint ] ++ lz.extraEfiSysMountPoints)}
      ${lib.optionalString measured.enable ''
        if test -e ${lib.escapeShellArg ready}; then
          ${makePolicy}
        fi
      ''}
    '');
    # Upstream starts these at sysinit. Before enrollment the same system must
    # also be able to boot in firmware Setup Mode using a console passphrase.
    systemd.services = lib.mkIf measured.enable (lib.genAttrs [
      "systemd-pcrlock-make-policy"
      "systemd-pcrlock-firmware-code"
      "systemd-pcrlock-firmware-config"
      "systemd-pcrlock-secureboot-policy"
      "systemd-pcrlock-secureboot-authority"
    ]
      (name: {
        serviceConfig.ExecStart = lib.mkIf (name == "systemd-pcrlock-make-policy") (lib.mkForce [ "" makePolicy ]);
        unitConfig = {
          ConditionSecurity = "uefi-secureboot";
          ConditionPathExists = lib.mkIf (name == "systemd-pcrlock-make-policy") ready;
        };
      }));
  };
}
