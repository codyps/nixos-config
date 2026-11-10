{ pkgs }:
let
  direnv = "${pkgs.direnv}/bin/direnv";
in
{
  # direnv 2.38.x regression (direnv#1653, commit 616e9bf / PR #1479): the
  # shipped zsh and bash hooks run `direnv export` before blocking SIGINT, so
  # Ctrl-C during a slow load interrupts the hook itself. direnv still prints
  # the diff that marks the RC as handled, but the interrupted shell throws it
  # away and the next prompt restarts the whole load (e.g. nix-direnv's
  # `nix print-dev-env`), making Ctrl-C useless. A no-op SIGINT trap keeps the
  # shell alive to evaluate that diff; trapped signals reset to the default
  # disposition in child processes, so direnv and the evaluation it runs are
  # still interrupted for real. Matches the approach proposed for bash in
  # direnv#1665; bash additionally needs a file capture because its
  # command-substitution subshell is killed with the terminal's process group.
  # Drop these overrides once a direnv release fixes both hooks.
  zshHook = ''
    eval "$(${direnv} hook zsh)"

    _direnv_hook() {
      setopt localoptions localtraps
      if [[ ! -o interactive || $ZSH_SUBSHELL -ne 0 ]]; then
        return
      fi
      trap -- ':' SIGINT
      vars="$(${direnv} export zsh)"
      trap -- ''' SIGINT
      eval "$vars"
      trap - SIGINT
    }
  '';

  bashHook = ''
    eval "$(${direnv} hook bash)"

    _direnv_hook() {
      local previous_exit_status=$?
      local previous_sigint_trap="$(trap -p SIGINT)"
      local tmp="''${TMPDIR:-/tmp}/.direnv-hook.$$" vars
      trap -- ':' SIGINT
      ${direnv} export bash > "$tmp"
      trap -- ''' SIGINT
      vars=$(< "$tmp")
      rm -f -- "$tmp"
      eval "$vars"
      eval "''${previous_sigint_trap:-trap - SIGINT}"
      return $previous_exit_status
    };
  '';
}
