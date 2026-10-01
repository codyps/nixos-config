{ config, lib, pkgs, ... }:
let
  cfg = config.programs.codex-config;
  configure = import ../nixpkgs/codex-configure.nix { inherit pkgs; };
in
{
  imports = [ ../modules/admin-commands.nix ];
  options.programs.codex-config = {
    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Users whose mutable Codex configuration is configured at activation.";
    };
    updateExisting = lib.mkEnableOption
      "applying Codex defaults to existing configs on every activation, preserving unrelated settings";
  };
  config = lib.mkIf (cfg.users != [ ]) {
    programs.adminCommands.commands.configure-codex = [ "${configure}/bin/codex-configure" ];
    environment.systemPackages = [ configure ];
    system.activationScripts.seedCodexConfig = {
      # runuser needs both the account and its PAM configuration on first boot.
      deps = [ "users" "etc" ];
      text = lib.concatMapStringsSep "\n"
        (user:
          let home = config.users.users.${user}.home;
          in ''
            ${pkgs.util-linux}/bin/runuser -u ${lib.escapeShellArg user} -- \
              ${configure}/bin/codex-configure ${lib.optionalString (!cfg.updateExisting) "--if-missing"} \
              --config ${lib.escapeShellArg "${home}/.codex/config.toml"} \
              --cache-home ${lib.escapeShellArg "${home}/.cache"}
          '')
        cfg.users;
    };
  };
}
