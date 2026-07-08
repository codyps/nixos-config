{
  programs.codex = {
    enable = true;
    settings = {
      # FIXME: we _probably_ need to wrap codex (and give it a custom bash
      # wrapper) to work around some of these.
      #
      # The use of bash login shell
      # screwing up environment could be worked around by hooking the
      # particular call codex does and not actually running a login shell.
      # Instead, we could just use a normal shell.
      #
      # sccache not working due to network blocking is attempted to be worked
      # around by the sandbox disables.
      #
      # similar for nix.
      #
      # The shell_environment_policy is to try to get direnv working
      #
      # https://github.com/openai/codex/issues/4843#issuecomment-3533072321
      # https://github.com/openai/codex/issues/25452
      # https://github.com/openai/codex/issues/4210
      # https://github.com/openai/codex/issues/16910
      sandbox_workspace_write = {
        network_access = true;
        sandbox_mode = "workspace-write";
      };
      shell_environment_policy = {
        "inherit" = "all";
        ignore_default_excludes = true;
      };
    };
  };
}
