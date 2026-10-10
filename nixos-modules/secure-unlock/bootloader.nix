{ config, lib, pkgs, ... }:
let
  cfg = config.boot.secureUnlock;
  lz = config.boot.lanzaboote;
  measured = lz.measuredBoot;
  ready = "${cfg.stateDirectory}/provisioning-ready";
  makePolicy = lib.escapeShellArgs (
    [
      "${config.systemd.package}/lib/systemd/systemd-pcrlock"
      "make-policy"
      "--components=${config.environment.etc.pcrlock.source}"
      "--components=${measured.pcrlockDirectory}"
      # Firmware measurement units write here, even when UKI measurements use
      # a host-specific persistent directory (notably Ward).
      "--components=/var/lib/pcrlock.d"
      "--policy=${measured.pcrlockPolicy}"
      "--location=770"
    ] ++ map (pcr: "--pcr=${toString pcr}") measured.pcrs
  );
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
  config = lib.mkIf cfg.enable {
    boot.loader.external.installHook = lib.mkForce (pkgs.writeShellScript "secure-unlock-install-bootloader" ''
      set -euo pipefail
      export PATH=${config.systemd.package}/lib/systemd:$PATH
      ${cfg.provisioningPackage}/bin/secure-unlock-setup prepare-install
      measurement_args=()
      ${lib.optionalString (measured.enable && builtins.elem 4 measured.pcrs) ''
        if test -e ${lib.escapeShellArg ready}; then
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
