{ config, lib, pkgs, ... }:
let
  configure = import ../nixpkgs/codex-configure.nix { inherit pkgs; };
in
{
  options.programs.codex-config.users = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Users whose mutable Codex configuration is seeded at activation.";
  };
  config = lib.mkIf (config.programs.codex-config.users != [ ]) {
    environment.systemPackages = [ configure ];
    system.activationScripts.seedCodexConfig = {
      # runuser needs both the account and its PAM configuration on first boot.
      deps = [ "users" "etc" ];
      text = lib.concatMapStringsSep "\n"
        (user:
          let home = config.users.users.${user}.home;
          in ''
            ${pkgs.util-linux}/bin/runuser -u ${lib.escapeShellArg user} -- \
              ${configure}/bin/codex-configure --if-missing \
              --config ${lib.escapeShellArg "${home}/.codex/config.toml"} \
              --cache-home ${lib.escapeShellArg "${home}/.cache"}
          '')
        config.programs.codex-config.users;
    };
  };
}
