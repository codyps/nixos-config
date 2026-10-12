{ config, lib, options, pkgs, ... }:
let
  cfg = config.services.hardwareIdentities;
  schema = builtins.fromJSON (builtins.readFile ../lib/hardware-identities-schema.json);
  host = config.networking.hostName or "";
  isNixos = options ? boot.initrd.systemd;
  hasZfs = schema.${host}.storage ? zfs;
  secure = isNixos && (config.boot.secureUnlock.enable or false);
  templates = lib.mapAttrs (name: value: pkgs.writeText "hardware-${baseNameOf name}" value.text) cfg.templates;
  manifest = pkgs.writeText "hardware-runtime.json" (builtins.toJSON {
    inherit host templates;
    inherit (cfg) stateDirectory allowFixtures;
    schema = ../lib/hardware-identities-schema.json;
    fixtures = ../config/hardware-fixtures/hardware-identities.json;
    byteOrder = if pkgs.stdenv.hostPlatform.isBigEndian then "big" else "little";
    mapper = if secure then config.boot.secureUnlock.mapperName else null;
    initrdTemplates = lib.optionalAttrs (config.boot.initrd.systemd.contents ? "/etc/crypttab")
      {
        "etc/crypttab" = config.boot.initrd.systemd.contents."/etc/crypttab".source;
      } // lib.optionalAttrs (config.boot.initrd.systemd.contents ? "/etc/systemd/network") {
      "etc/systemd/network" = config.boot.initrd.systemd.contents."/etc/systemd/network".source;
    }
    // lib.filterAttrs (name: _: cfg.templates.${name}.initrd) templates;
    secrets = lib.mapAttrs (dest: source: if source == null then dest else toString source) config.boot.initrd.secrets;
  });
  scripts = pkgs.runCommand "hardware-runtime-scripts" { } ''
    mkdir -p "$out"
    cp ${../scripts/hardware-identities.py} "$out/hardware-identities.py"
    cp ${../scripts/hardware-runtime.py} "$out/hardware-runtime.py"
  '';
  helper = pkgs.writeShellApplication {
    name = "hardware-runtime";
    runtimeInputs = [ pkgs.python3 pkgs.sops pkgs.gnupg ];
    text = ''exec python3 ${scripts}/hardware-runtime.py --manifest ${manifest} "$@"'';
  };
  run = "${helper}/bin/hardware-runtime";
  rule = ''
    # Matches are evaluated before imports within a rule. Consume the imported
    # property in a separate rule, and discard any value from an earlier event.
    SUBSYSTEM=="block", ENV{HARDWARE_LINKS}=""
    SUBSYSTEM=="block", ENV{ID_FS_UUID}=="?*", IMPORT{file}="/etc/nixos-hardware/devices/$env{ID_FS_UUID}"
    SUBSYSTEM=="block", ENV{HARDWARE_LINKS}=="?*", SYMLINK+="$env{HARDWARE_LINKS}"
  '';
in
{
  imports = [ ./admin-commands.nix ];
  options.services.hardwareIdentities = {
    enable = lib.mkOption { type = lib.types.bool; default = isNixos && builtins.hasAttr host schema; };
    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = if (config.fileSystems or { }) ? "/persist" then "/persist/nixos-hardware" else "/var/lib/nixos-hardware";
      description = "Persistent, machine-local hardware inventory and rendered files.";
    };
    allowFixtures = lib.mkOption { type = lib.types.bool; default = false; internal = true; };
    templates = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          text = lib.mkOption { type = lib.types.lines; };
          initrd = lib.mkOption { type = lib.types.bool; default = false; };
        };
      });
    };
  };
  config = lib.optionalAttrs isNixos (lib.mkIf cfg.enable (lib.mkMerge [{
    assertions = [
      { assertion = config.boot.initrd.systemd.enable; message = "Local hardware provisioning requires the systemd initrd."; }
      { assertion = config.boot.loader.supportsInitrdSecrets; message = "Local hardware provisioning requires a bootloader with initrd append support."; }
    ];
    programs.adminCommands.commands = {
      hardware-provision = [ run "provision" ];
      hardware-verify = [ run "verify" ];
    };
    system.build.hardwareProvisioner = helper;
    system.preSwitchChecks.hardware-identities = ''${run} verify'';
    system.activationScripts.hardware-identities = {
      deps = [ "specialfs" ];
      text = ''
        ${run} render || exit 1
        mkdir -p /run/nixos
        ${lib.optionalString config.systemd.network.enable ''echo systemd-networkd.service >> /run/nixos/activation-reload-list''}
        ${lib.optionalString (config.services.usbguard.enable or false) ''echo usbguard.service >> /run/nixos/activation-restart-list''}
      '';
    };
    system.activationScripts.etc.deps = [ "hardware-identities" ];
    environment.etc = {
      "nixos-hardware".source = "${cfg.stateDirectory}/current/etc/nixos-hardware";
    } // lib.optionalAttrs hasZfs {
      "hostid".source = lib.mkForce "${cfg.stateDirectory}/current/etc/hostid";
    } // lib.mapAttrs'
      (name: _: lib.nameValuePair (lib.removePrefix "etc/" name) {
        source = "${cfg.stateDirectory}/current/${name}";
      })
      (lib.filterAttrs (name: _: lib.hasPrefix "etc/" name && !(lib.hasPrefix "etc/nixos-hardware/" name)) templates);
    services.udev.extraRules = rule;
    boot.initrd.services.udev.rules = rule;
    # A nonempty secrets set makes NixOS advertise its late appender in bootspec.
    # The appender writes hardware files directly into the archive, so they are
    # present before systemd generators and udev start, not copied by a service.
    boot.initrd.secrets."hardware-inventory-marker" = "${cfg.stateDirectory}/input/metadata.json";
    system.build.initialRamdiskSecretAppender = lib.mkForce (pkgs.writeShellScriptBin "append-initrd-secrets" ''
      exec ${run} append "$@"
    '');
  }
    (lib.optionalAttrs (options ? boot.secureUnlock.rootVolumeKeyIdFile) {
      boot.secureUnlock.rootVolumeKeyIdFile = "${cfg.stateDirectory}/current/root-volume-key-id.json";
    })]));
}
