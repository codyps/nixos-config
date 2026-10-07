{ config, lib, pkgs, ... }:
let
  cfg = config.services.codex-remote-control;
  home = config.users.users.${cfg.user}.home;
  cli = pkgs.writeShellScript "codex-service-cli" ''
    set -euo pipefail
    if [[ $(/usr/bin/id -un) != ${lib.escapeShellArg cfg.user} ]]; then
      echo 'Run this command as ${cfg.user}, without sudo.' >&2
      exit 1
    fi
    export HOME=${lib.escapeShellArg home}
    export CODEX_HOME="$HOME/.codex"
    current="$CODEX_HOME/packages/standalone/current"
    codex="$current/bin/codex"
    if [[ ! -x "$codex" ]]; then codex="$current/codex"; fi
    exec "$codex" "$@"
  '';
  service = pkgs.writeShellScript "codex-remote-control" ''
    set -euo pipefail
    umask 077
    export CODEX_INSTALL_DIR="$HOME/.local/share/codex-bin"
    export CODEX_NON_INTERACTIVE=1
    export PATH="$CODEX_INSTALL_DIR:$PATH"
    current="$CODEX_HOME/packages/standalone/current"
    if [[ ! -x "$current/bin/codex" && ! -x "$current/codex" ]]; then
      installer=$(mktemp)
      trap 'rm -f "$installer"' EXIT
      curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 30 --max-time 120 \
        https://chatgpt.com/codex/install.sh -o "$installer"
      sh "$installer"
      rm -f "$installer"
      trap - EXIT
    fi
    # Reuse an existing native daemon (including SSH sessions) instead of
    # competing for its control socket. Bootstrap also enables remote control
    # on a running daemon and manages its eligible native updater.
    ${cli} app-server daemon bootstrap --remote-control
    while sleep 30; do
      if ! ${cli} app-server daemon start >/dev/null; then
        echo 'Codex health check failed; retrying in 30 seconds.' >&2
      fi
    done
  '';
  status = pkgs.writeShellScript "codex-remote-control-status" ''
    /bin/launchctl print system/org.nixos.codex-remote-control
    exec ${cli} app-server daemon version
  '';
in
{
  imports = [ ../../modules/admin-commands.nix ];

  options.services.codex-remote-control = {
    enable = lib.mkEnableOption "boot-time Codex remote control through launchd";
    user = lib.mkOption {
      type = lib.types.str;
      default = config.system.primaryUser;
      description = "Existing account whose Codex installation and credentials the service uses.";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.adminCommands.commands = {
      codex-status = [ "${status}" ];
      restart-codex = [ "${cli}" "app-server" "daemon" "restart" ];
    };
    launchd.daemons.codex-remote-control = {
      command = "${service}";
      path = [ "${home}/.local/bin" "${home}/.nix-profile/bin" "/etc/profiles/per-user/${cfg.user}/bin" "/run/current-system/sw/bin" ]
        ++ map (package: "${package}/bin") [ pkgs.coreutils pkgs.curl pkgs.gnutar pkgs.gzip pkgs.git pkgs.openssh ]
        ++ [ "/usr/bin" "/bin" "/usr/sbin" "/sbin" ];
      environment = {
        HOME = home;
        CODEX_HOME = "${home}/.codex";
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      };
      serviceConfig = {
        UserName = cfg.user;
        WorkingDirectory = home;
        RunAtLoad = true;
        KeepAlive = true;
        # The native daemon/updater own their lifecycles. Reloading this
        # watchdog must not terminate their active sessions.
        AbandonProcessGroup = true;
        ThrottleInterval = 30;
        Umask = 63; # 0077
        # launchd opens these as UserName before executing the script. Use the
        # existing home directory so first startup needs no root-created log.
        StandardOutPath = "${home}/.codex-remote-control.log";
        StandardErrorPath = "${home}/.codex-remote-control.log";
      };
    };
  };
}
