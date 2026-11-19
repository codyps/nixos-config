{ pkgs }:

pkgs.writeShellScript "check-claude-attribution" ''
  mode=$1
  input=$2
  claude_attribution=$(${pkgs.gawk}/bin/awk -v mode="$mode" '
    BEGIN { IGNORECASE = 1 }
    mode == "commit" && /^# ------------------------ >8 ------------------------$/ { exit }
    /^[[:blank:]]*Co-authored-by:[[:blank:]]*/ {
      sub(/^[[:blank:]]*Co-authored-by:[[:blank:]]*/, "")
      if ($0 ~ /^Claude([[:blank:]<]|$)/ || $0 ~ /<noreply@anthropic\.com>[[:space:]]*$/) {
        print FNR ": " $0
      }
    }
  ' < "$input") || exit 1
  if [ -n "$claude_attribution" ] &&
    [ "''${GIT_ALLOW_CLAUDE_COAUTHOR:-}" != 1 ] &&
    [ "$(git config --local --type=bool --get hooks.allowClaudeCoAuthor)" != true ] &&
    ! git grep --cached --quiet --basic-regexp \
      -e '^Please include Claude co-author trailers\.$' -- \
      ':(top,icase)AGENTS.md' ':(top,icase)CLAUDE.md' ':(top,glob,icase)README*' \
      ':(top,glob,icase)docs/**/*.md'; then
    if [ "$mode" = commit ]; then
      command="git commit"
      subject="commit message"
      prefix=commit-msg
    else
      command="gh pr $mode"
      subject="pull request description"
      prefix="$command"
    fi
    echo "$prefix: Claude co-author attribution requires repository opt-in:" >&2
    printf '%s\n' "$claude_attribution" >&2
    echo "Remove the listed Co-authored-by lines from the $subject and rerun $command." >&2
    echo "Enable Claude co-author attribution only when the repository's documentation explicitly requests it." >&2
    echo "For a documented opt-in, use the exact line 'Please include Claude co-author trailers.'" >&2
    echo "If the repository explicitly requests attribution, use either override:" >&2
    echo "  This invocation: GIT_ALLOW_CLAUDE_COAUTHOR=1 $command" >&2
    echo "  This repository: git config --local hooks.allowClaudeCoAuthor true" >&2
    exit 1
  fi
''
