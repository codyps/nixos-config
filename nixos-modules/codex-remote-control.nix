{ config, lib, pkgs, ... }:
let
  cfg = config.services.codex-remote-control;
  home = config.users.users.${cfg.user}.home;
  python = pkgs.python3.withPackages (p: [ p.websockets ]);
in
{
  imports = [ ../modules/admin-commands.nix ];
  options.services.codex-remote-control = {
    enable = lib.mkEnableOption "remote control recovery for an existing Codex server";
    user = lib.mkOption {
      type = lib.types.str;
      default = "cody";
      description = "Account owning the Codex app-server socket.";
    };
  };
  config = lib.mkIf cfg.enable {
    users.users.${cfg.user}.linger = true;
    programs.adminCommands.commands.enable-codex-remote-control = [
      "${pkgs.systemd}/bin/systemctl"
      "--user"
      "start"
      "codex-remote-control.service"
    ];
    # Enable through RPC: native remote-control start refuses servers launched
    # directly by desktop/SSH clients. Never restart a server with active turns.
    systemd.user.services.codex-remote-control = {
      description = "Restore Codex remote control on the running server";
      unitConfig = {
        ConditionUser = cfg.user;
        ConditionPathExists = "${home}/.codex/app-server-control/app-server-control.sock";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${python}/bin/python3 ${./ai-container/codex-remote-control.py} ${home}/.codex/app-server-control/app-server-control.sock";
        TimeoutStartSec = "45s";
        UMask = "0077";
      };
    };
    systemd.user.timers.codex-remote-control = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnStartupSec = "10s";
        OnCalendar = "*-*-* *:*:00";
        AccuracySec = "5s";
      };
    };
  };
}
