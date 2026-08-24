{ pkgs, ... }:

# Global git hooks that reject em-dashes (U+2014, "—") in commit messages and
# in staged commit content, and point out where they are. Set GIT_ALLOW_EMDASH=1
# to bypass for a single commit.
#
# NOTE: git only honours a single core.hooksPath, so this takes over global hook
# dispatch. Per-repo hooks in .git/hooks are ignored while this is active.
let
  emdash = ''$'\xe2\x80\x94' ''; # UTF-8 bytes for U+2014, evaluated by bash

  # Scan staged additions for em-dashes, reporting file:line: text.
  preCommit = pkgs.writeShellScript "pre-commit" ''
    set -o pipefail
    if [ "''${GIT_ALLOW_EMDASH:-}" = "1" ]; then
      exit 0
    fi
    emdash=${emdash}
    report=$(git diff --cached --unified=0 --no-color --diff-filter=ACM \
      | ${pkgs.gawk}/bin/awk -v e="$emdash" '
          /^\+\+\+ / { file = substr($0, 5); sub(/^b\//, "", file); next }
          /^@@ /     { n = $3; sub(/^\+/, "", n); sub(/,.*/, "", n); ln = n + 0; next }
          /^\+/ {
            text = substr($0, 2)
            if (index(text, e) > 0) { printf "  %s:%d: %s\n", file, ln, text; found = 1 }
            ln++
            next
          }
          END { if (found) exit 1 }
      ') && rc=0 || rc=1
    if [ "$rc" -ne 0 ]; then
      echo "pre-commit: em-dash (—) found in staged changes:" >&2
      printf '%s\n' "$report" >&2
      echo "" >&2
      echo "Replace the em-dashes, or set GIT_ALLOW_EMDASH=1 to bypass." >&2
      exit 1
    fi
  '';

  # Scan the commit message (ignoring comments and the verbose diff below the
  # scissors line) for em-dashes, reporting line: text.
  commitMsg = pkgs.writeShellScript "commit-msg" ''
    set -o pipefail
    if [ "''${GIT_ALLOW_EMDASH:-}" = "1" ]; then
      exit 0
    fi
    emdash=${emdash}
    report=$(${pkgs.gawk}/bin/awk -v e="$emdash" '
      /^#.*>8/ { exit }
      /^#/     { next }
      { if (index($0, e) > 0) { printf "  %d: %s\n", FNR, $0; found = 1 } }
      END { if (found) exit 1 }
    ' "$1") && rc=0 || rc=1
    if [ "$rc" -ne 0 ]; then
      echo "commit-msg: em-dash (—) found in commit message:" >&2
      printf '%s\n' "$report" >&2
      echo "" >&2
      echo "Replace the em-dashes, or set GIT_ALLOW_EMDASH=1 to bypass." >&2
      exit 1
    fi
  '';

  hooks = pkgs.runCommandLocal "git-emdash-hooks" { } ''
    mkdir -p "$out"
    ln -s ${preCommit} "$out/pre-commit"
    ln -s ${commitMsg} "$out/commit-msg"
  '';
in
{
  programs.git.settings.core.hooksPath = "${hooks}";
}
