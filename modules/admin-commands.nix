{ config, lib, options, pkgs, ... }:
let
  cfg = config.programs.adminCommands;
  dispatcher = pkgs.writeShellScriptBin "sys" ''
    # An explicit generation's sw/bin/sys must use that generation's helpers.
    case "$0" in
      */*) export PATH="''${0%/*}:$PATH" ;;
    esac
    exec ${pkgs.python3}/bin/python3 -I ${../scripts/sys.py} "$@"
  '';
  commands = lib.mapAttrsToList
    (name: argv: pkgs.writeShellScriptBin "sys-${name}" ''
      exec ${lib.escapeShellArgs argv} "$@"
    '')
    cfg.commands;
  packages = [ dispatcher ] ++ commands;
in
{
  options.programs.adminCommands.commands = lib.mkOption {
    type = lib.types.attrsOf (lib.types.nonEmptyListOf lib.types.str);
    default = { };
    description = "Repository administration commands: kebab-case names mapped to an executable and fixed arguments. Use absolute store paths for executables.";
  };
  config = lib.mkMerge [
    {
      assertions = lib.mapAttrsToList
        (name: argv: {
          assertion = builtins.match "[a-z0-9]+(-[a-z0-9]+)*" name != null && name != "help";
          message = "Invalid administration command name: ${name}";
        })
        cfg.commands;
    }
    (lib.optionalAttrs (options ? environment.systemPackages) {
      environment.systemPackages = packages;
    })
    (lib.optionalAttrs (options ? home.packages) {
      home.packages = packages;
    })
  ];
}
