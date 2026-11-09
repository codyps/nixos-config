# Run OpenCode agent tools inside the crow-ai container, per project.
#
# The system configuration never loads this plugin. `opencode-sandbox.nix`
# only builds the plugin (with its options baked in) and registers admin
# commands:
#
#   sys opencode-sandbox-enable <dir>    add the plugin to <dir>/.opencode/opencode.json
#   sys opencode-sandbox-disable <dir>   remove it (OpenCode hot-reloads it away)
#   sys opencode-sandbox-check           probe the SSH channel to crow-ai
#
# Only sessions anchored inside a project that ran `enable` are sandboxed;
# everything else on the server is untouched, and disabling is instant,
# with no rebuild. The OpenCode server always stays on the Crow host:
# provider traffic, managed settings, sessions, and secrets never enter
# the container. Sandboxed sessions run their shell as the container's
# cody-ai account over SSH; the host-executing filesystem tools are
# removed for those projects (file work goes through the sandboxed shell),
# and everything fails closed when the container is unreachable.
#
# Authentication uses cody's host key (~/.ssh/id_ed25519), which the
# container's cody-ai account accepts through nixos/ssh-auth.nix. The
# container's host key is trusted on first use and pinned in
# /var/lib/opencode/sandbox-known-hosts. Host session directories map onto
# the container's workspace root (/home/cody/<project> becomes
# /home/cody-ai/workspaces/<project>); the shell tool creates the mapped
# directory on first use.
#
# Project configs reference the plugin through the stable symlink
# /var/lib/opencode/sandbox-plugin, refreshed on every activation, so a
# rebuild does not orphan them. Re-run `sys opencode-sandbox-enable <dir>`
# after a rebuild changes the plugin to make OpenCode reload it.
{ config, lib, pkgs, ... }:

let
  containerAddress = "10.80.0.2";
  containerUser = "cody-ai";
  identityFile = "/home/cody/.ssh/id_ed25519";
  knownHostsFile = "/var/lib/opencode/sandbox-known-hosts";
  pluginLink = "/var/lib/opencode/sandbox-plugin";

  pluginOptions = {
    sshBinary = "${pkgs.openssh}/bin/ssh";
    host = containerAddress;
    user = containerUser;
    keyFile = identityFile;
    inherit knownHostsFile;
    defaultTimeoutMs = 120000;
    mappings = [ { host = "/home/cody"; guest = "/home/cody-ai/workspaces"; } ];
  };

  # Bake the options into the plugin source; this OpenCode release does
  # not deliver plugin options from project config entries, so the plugin
  # also merges ctx.options when a newer release provides them.
  renderedPlugin = lib.replaceStrings
    [ "\"@@SANDBOX_OPTIONS_JSON@@\"" ]
    [ (builtins.toJSON (builtins.toJSON pluginOptions)) ]
    (builtins.readFile ./opencode-sandbox-plugin/index.ts);
  plugin = pkgs.runCommand "opencode-sandbox-plugin" { } ''
    install -Dm 0644 ${pkgs.writeText "opencode-sandbox-index.ts" renderedPlugin} $out/index.ts
  '';

  # The plugins entry `enable` merges into a project config. The package
  # path is the stable symlink; options are kept for forward compatibility.
  entryFile = pkgs.writeText "opencode-sandbox-entry.json" (builtins.toJSON {
    plugins = [ { package = pluginLink; } ];
  });
  initialFile = pkgs.writeText "opencode-sandbox-initial.json" (builtins.toJSON {
    "$schema" = "https://opencode.ai/config.json";
    plugins = [ { package = pluginLink; } ];
  });

  enableScript = pkgs.writeShellApplication {
    name = "opencode-sandbox-enable";
    runtimeInputs = with pkgs; [ coreutils jq ];
    text = ''
      set -euo pipefail
      dir="''${1:-$PWD}"
      if [ ! -d "$dir" ]; then
        echo "usage: sys opencode-sandbox-enable [project-dir]" >&2
        echo "no such directory: $dir" >&2
        exit 1
      fi
      file="$dir/.opencode/opencode.json"
      mkdir -p -- "$dir/.opencode"
      tmp=$(mktemp)
      trap 'rm -f -- "$tmp"' EXIT
      if [ -e "$file" ]; then
        jq --slurpfile sandbox ${entryFile} \
          '.plugins = ((.plugins // []) | map(select((.package // "") | ((contains("opencode/sandbox-plugin") or contains("opencode-sandbox-plugin")) | not))) + $sandbox[0].plugins)' \
          "$file" > "$tmp"
      else
        cp ${initialFile} "$tmp"
      fi
      mv -- "$tmp" "$file"
      trap - EXIT
      # Root invocations must not leave root-owned files in user projects.
      chown "$(stat -c '%U:%G' -- "$dir")" -- "$file" 2>/dev/null || true
      echo "Sandbox enabled for $dir (sessions there run tools in crow-ai)."
      echo "Disable with: sys opencode-sandbox-disable $dir"
    '';
  };

  disableScript = pkgs.writeShellApplication {
    name = "opencode-sandbox-disable";
    runtimeInputs = with pkgs; [ coreutils jq ];
    text = ''
      set -euo pipefail
      dir="''${1:-$PWD}"
      file="$dir/.opencode/opencode.json"
      if [ ! -e "$file" ]; then
        echo "No .opencode/opencode.json in $dir; nothing to disable." >&2
        exit 1
      fi
      tmp=$(mktemp)
      trap 'rm -f -- "$tmp"' EXIT
      jq '.plugins = ((.plugins // []) | map(select((.package // "") | ((contains("opencode/sandbox-plugin") or contains("opencode-sandbox-plugin")) | not))) | if length == 0 then empty else . end)' \
        "$file" > "$tmp"
      mv -- "$tmp" "$file"
      trap - EXIT
      chown "$(stat -c '%U:%G' -- "$dir")" -- "$file" 2>/dev/null || true
      echo "Sandbox disabled for $dir (OpenCode reloads the change)."
    '';
  };

  check = pkgs.writeShellScript "opencode-sandbox-check" ''
    set -euo pipefail
    echo "Probing OpenCode sandbox channel ${containerUser}@${containerAddress}"
    exec ${pkgs.openssh}/bin/ssh \
      -F /dev/null \
      -o BatchMode=yes \
      -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile=${knownHostsFile} \
      -o ConnectTimeout=10 \
      -i ${identityFile} \
      ${containerUser}@${containerAddress} \
      'printf "host: "; hostname; printf "user: "; id -un; printf "kernel: "; uname -r; printf "workspaces: "; ls -1A ~/workspaces 2>/dev/null | head -5 || true'
  '';
in
{
  config = lib.mkIf config.services.opencode.server.enable {
    # Persistent state for the SSH known-hosts file and the tool
    # definition dump (cody-owned via the unit user).
    systemd.services.opencode-server = {
      serviceConfig.StateDirectory = [ "opencode" ];
      # Keep the stable plugin path pointing at the current build so
      # project configs survive rebuilds.
      serviceConfig.ExecStartPre =
        [ "-${pkgs.coreutils}/bin/ln -sfn ${plugin} ${pluginLink}" ];
    };

    # sys opencode-sandbox-enable / -disable / -check
    programs.adminCommands.commands = {
      opencode-sandbox-enable = [ "${enableScript}/bin/opencode-sandbox-enable" ];
      opencode-sandbox-disable = [ "${disableScript}/bin/opencode-sandbox-disable" ];
      opencode-sandbox-check = [ "${check}" ];
    };
  };
}
