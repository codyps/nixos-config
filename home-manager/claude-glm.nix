{ config, pkgs, ... }:
let
  claudeDir = "${config.home.homeDirectory}/.claude";
  # Run Claude Code against z.ai's GLM models. The settings and MCP files hold
  # the z.ai API key, so they stay unmanaged in ~/.claude rather than the store.
  claude-glm = pkgs.writeShellScriptBin "claude-glm" ''
    settings="''${CLAUDE_GLM_SETTINGS:-${claudeDir}/glm-settings.json}"
    mcp="''${CLAUDE_GLM_MCP_CONFIG:-${claudeDir}/glm-mcp.json}"
    for f in "$settings" "$mcp"; do
      if [ ! -r "$f" ]; then
        echo "claude-glm: missing $f" >&2
        exit 1
      fi
    done
    exec claude --settings "$settings" --mcp-config "$mcp" "$@"
  '';
in
{
  home.packages = [ claude-glm ];
}
