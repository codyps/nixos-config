{ config, lib, pkgs, ... }:
let
  user = "cody-ai";
  home = "/home/${user}";
  socket = "${home}/.codex/app-server-control/app-server-control.sock";
  inherit (import ../../nixos/ssh-auth.nix) authorizedKeys;
  # Optional compatibility for clients that launch a JSON-lines app server.
  # Native daemon discovery and proxying do not need this adapter.
  transportPython = pkgs.python3.withPackages (p: [ p.websockets ]);
  supervisor = pkgs.writeShellScript "codex-ai-service" (builtins.readFile ./codex-service.sh);
  codexRemote = pkgs.writeShellScriptBin "codex" ''
    export CODEX_HOME=${home}/.codex
    current="$CODEX_HOME/packages/standalone/current"
    codex="$current/bin/codex"
    if [ ! -x "$codex" ]; then codex="$current/codex"; fi
    if [ ! -x "$codex" ]; then
      echo 'Codex has not been installed by codex-ai.service yet.' >&2
      exit 1
    fi
    if [ "''${1-}" = remote-control ] && [ "''${2-}" != pair ]; then
      echo 'Remote control runs in codex-ai.service; use codex remote-control pair to pair a phone.' >&2
      exit 1
    fi
    if [ "''${1-}" = app-server ]; then
      shift
      if [ "''${1-}" = daemon ]; then
        case "''${2-}" in
          start|version)
            # Probe only: even a stale socket must not cause a detached launch
            # outside systemd's sandbox.
            if [ ! -S ${socket} ]; then
              echo 'codex-ai.service is not ready; contact the administrator.' >&2
              exit 1
            fi
            exec "$codex" app-server daemon version
            ;;
        esac
        echo 'Codex lifecycle is managed by codex-ai.service.' >&2
        exit 1
      fi
      if [ "''${1-}" = proxy ]; then
        exec "$codex" app-server proxy --sock ${socket}
      fi
      ${lib.optionalString (!config.services.codex-ai.stdioForwarder.enable) ''
        echo 'Custom stdio forwarding is disabled; use the native app-server proxy.' >&2
        exit 1
      ''}
      ${lib.optionalString config.services.codex-ai.stdioForwarder.enable ''
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --stdio|--analytics-default-enabled) shift ;;
          --listen)
            [ "''${2-}" = stdio:// ] || exit 2
            shift 2
            ;;
          *)
            echo "Unsupported managed app-server argument: $1" >&2
            exit 2
            ;;
        esac
      done
      exec ${transportPython}/bin/python3 ${./codex-stdio.py} ${socket}
      ''}
    fi
    exec "$codex" "$@"
  '';
in
{
  options.services.codex-ai.stdioForwarder.enable = lib.mkEnableOption
    "the custom JSON-lines stdio compatibility adapter for Codex";

  config = {
    users.groups.${user} = { };
    users.users.${user} = {
      isNormalUser = true;
      description = "Cody's isolated AI harness account";
      group = user;
      extraGroups = [ ];
      inherit home;
      homeMode = "0700";
      hashedPassword = "!";
      shell = pkgs.bashInteractive;
      packages = [ codexRemote pkgs.git pkgs.ripgrep pkgs.jq pkgs.python3 ];
      openssh.authorizedKeys.keys = map (key: "restrict,pty ${key}") authorizedKeys;
    };

    # Also enforce permissions on an existing home; /home is already persistent.
    users.users.cody.homeMode = "0700";
    systemd.tmpfiles.rules = [
      "d ${home} 0700 ${user} ${user} -"
      "d ${home}/workspaces 0700 ${user} ${user} -"
      "d ${home}/.codex 0700 ${user} ${user} -"
      "z /home/cody 0700 cody users -"
    ];

    services.openssh.extraConfig = ''
      Match User ${user}
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        DisableForwarding yes
        PermitUserRC no
      Match all
    '';
    # Neither sudo nor a desktop policy agent should confer host privileges.
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (subject.user == "${user}") return polkit.Result.NO;
      });
    '';
    # Builds through the host daemon execute outside the service mount sandbox.
    nix.settings.allowed-users = lib.mkForce [ "root" "cody" "nix-ssh" "@wheel" ];

    systemd.services.codex-ai = {
      description = "Codex app server for Cody's AI harness account";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "systemd-tmpfiles-setup.service" ];
      unitConfig.RequiresMountsFor = [ home ];
      path = with pkgs; [ bashInteractive coreutils procps curl cacert gnutar gzip gnugrep gnused gawk findutils git ripgrep jq python3 openssh ];
      environment = {
        HOME = home;
        CODEX_HOME = "${home}/.codex";
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      };
      serviceConfig = {
        Type = "simple";
        User = user;
        Group = user;
        WorkingDirectory = "${home}/workspaces";
        ExecStart = supervisor;
        KillMode = "control-group";
        TimeoutStopSec = 30;
        Restart = "always";
        RestartSec = 30;
        UMask = "0077";
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        ProtectSystem = "strict";
        ProtectHome = "tmpfs";
        BindPaths = [ home ];
        ReadWritePaths = [ home ];
        InaccessiblePaths = [ "-/persist" "-/run/secrets" "-/run/user" "-/run/dbus" "-/run/systemd/private" "-/nix/var/nix/daemon-socket" ];
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        SystemCallArchitectures = "native";
        TasksMax = "infinity";
        # User namespaces remain available for Codex's own Linux sandbox.
      };
    };

    assertions = [{
      assertion = config.users.users.${user}.extraGroups == [ ];
      message = "The AI harness account must not have supplementary groups.";
    }];
  };
}
