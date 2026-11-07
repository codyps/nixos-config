{ config, lib, pkgs, ... }:
let
  cfg = config.services.opencode;
  server = cfg.server;
  defaultPort = 49375;
  home = config.users.users.${server.user}.home;
  start = pkgs.writeShellScript "opencode-server" ''
    set -euo pipefail
    export OPENCODE_PASSWORD="$(cat "''${CREDENTIALS_DIRECTORY:?}/password")"
    exec ${cfg.package}/bin/opencode serve \
      --hostname ${lib.escapeShellArg server.hostname} \
      --port ${toString server.port}
  '';
in
{
  options.services.opencode = {
    enable = lib.mkEnableOption "OpenCode";
    package = lib.mkPackageOption pkgs "opencode" { };
    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = ''
        Managed machine-wide OpenCode configuration. Written to
        /etc/opencode/opencode.json, which OpenCode treats as read-only and
        applies with higher precedence than user and project configuration.
      '';
    };
    server = {
      enable = lib.mkEnableOption "the OpenCode server daemon";
      user = lib.mkOption {
        type = lib.types.str;
        default = "cody";
        description = "Account that owns the server process and its data.";
      };
      hostname = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Address the server listens on.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = defaultPort;
        description = "TCP port the server listens on.";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        description = ''
          File containing the OpenCode server password. Loaded as a systemd
          credential, so it does not need to be readable by the service user.
          Required when the server is enabled.
        '';
      };
      tailscaleServe = {
        enable = lib.mkEnableOption "a Tailscale Serve TCP proxy to the server";
        port = lib.mkOption {
          type = lib.types.port;
          default = defaultPort;
          description = "Tailnet TCP port exposed by Tailscale Serve.";
        };
        httpsPort = lib.mkOption {
          type = lib.types.nullOr lib.types.port;
          default = null;
          description = ''
            HTTPS port for a Tailscale Serve HTTPS proxy. Set to 443 to expose
            the server as the node's standard HTTPS service.
          '';
        };
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.etc."opencode/opencode.json".text = builtins.toJSON cfg.settings + "\n";
      environment.systemPackages = [ cfg.package ];
    })
    (lib.mkIf (cfg.enable && server.enable) {
      assertions = [
        {
          assertion = server.passwordFile != null;
          message = "services.opencode.server.passwordFile is required when the server is enabled.";
        }
      ];
      systemd.services.opencode-server = {
        description = "OpenCode server";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" "sops-install-secrets.service" ];
        after = [ "network-online.target" "sops-install-secrets.service" ];
        environment = {
          HOME = home;
          PATH = lib.mkForce "/run/current-system/sw/bin:/etc/profiles/per-user/${server.user}/bin";
        };
        serviceConfig = {
          Type = "simple";
          User = server.user;
          WorkingDirectory = home;
          ExecStart = start;
          LoadCredential = [ "password:${server.passwordFile}" ];
          RuntimeDirectory = "opencode-server";
          RuntimeDirectoryMode = "0700";
          Environment = [ "XDG_RUNTIME_DIR=/run/opencode-server" ];
          Restart = "always";
          RestartSec = 5;
          UMask = "0077";
        };
      };
      systemd.services.opencode-tailscale-serve = lib.mkIf server.tailscaleServe.enable {
        description = "Expose the OpenCode server over Tailscale";
        wantedBy = [ "multi-user.target" ];
        wants = [ "tailscaled.service" ];
        after = [ "tailscaled.service" "opencode-server.service" ];
        requires = [ "opencode-server.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = 10;
          ExecStart = "${pkgs.tailscale}/bin/tailscale serve --bg --tcp=${toString server.tailscaleServe.port} tcp://127.0.0.1:${toString server.port}";
          ExecStop = "${pkgs.tailscale}/bin/tailscale serve --tcp=${toString server.tailscaleServe.port} off";
        };
      };
      systemd.services.opencode-tailscale-https = lib.mkIf
        (
          server.tailscaleServe.enable && server.tailscaleServe.httpsPort != null
        )
        {
          description = "Expose the OpenCode server over Tailscale HTTPS";
          wantedBy = [ "multi-user.target" ];
          wants = [ "tailscaled.service" ];
          after = [ "tailscaled.service" "opencode-server.service" ];
          requires = [ "opencode-server.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            Restart = "on-failure";
            RestartSec = 10;
            ExecStart = "${pkgs.tailscale}/bin/tailscale serve --bg --https=${toString server.tailscaleServe.httpsPort} http://127.0.0.1:${toString server.port}";
            ExecStop = "${pkgs.tailscale}/bin/tailscale serve --https=${toString server.tailscaleServe.httpsPort} off";
          };
        };
    })
  ];
}
