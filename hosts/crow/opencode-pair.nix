# Mint one-time pairing links for Crow's OpenCode servers.
#
# `opencode pair` only pairs the caller's shared background service: it
# rejects `--server`, so it cannot target the standalone `opencode serve`
# daemons this host runs. The helper asks the running server to mint a
# single-use code through its HTTP API instead (`POST /api/pair`, the same
# endpoint `opencode pair` uses) and prints a public /auth/connect/<code>
# link for the matching Tailscale Serve origin:
#
#   sudo sys opencode-pair host        cody's server, https://crow.little-moth.ts.net:8443
#   sudo sys opencode-pair container   crow-ai's server, https://crow.little-moth.ts.net:8444
#
# Links work once and expire in 5 minutes; the sessions they create last
# 30 days. Reading the password secret requires root. The container target
# needs the crow-ai container running (opencode-container.nix).
{ config, lib, pkgs, ... }:

let
  hostOrigin = "http://127.0.0.1:49375";
  containerOrigin = "http://10.80.0.2:49375";
  hostPublic = "https://crow.little-moth.ts.net:8443";
  containerPublic = "https://crow.little-moth.ts.net:8444";
  passwordFile = config.sops.secrets.opencode-password.path;
  opencode = config.services.opencode.package;

  pairScript = pkgs.writeShellApplication {
    name = "opencode-pair";
    runtimeInputs = with pkgs; [ jq ];
    text = ''
      set -euo pipefail
      target="''${1:-host}"
      case "$target" in
        host)
          origin=${hostOrigin}
          public=${hostPublic}
          ;;
        container)
          origin=${containerOrigin}
          public=${containerPublic}
          ;;
        *)
          echo "usage: sys opencode-pair [host|container]" >&2
          exit 1
          ;;
      esac
      code=$(OPENCODE_PASSWORD="$(cat ${passwordFile})" \
        ${opencode}/bin/opencode api --server "$origin" post /api/pair \
        | jq -r .code)
      echo "$public/auth/connect/$code"
      echo "Single-use link; it expires in 5 minutes. Run again for a new one."
    '';
  };
in
{
  config = lib.mkIf config.services.opencode.server.enable {
    programs.adminCommands.commands.opencode-pair = [ "${pairScript}/bin/opencode-pair" ];
  };
}
