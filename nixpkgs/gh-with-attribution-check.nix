{ pkgs, gh }:

let
  checkClaudeAttribution = import ../lib/claude-attribution.nix { inherit pkgs; };
  wrapper = pkgs.writeShellScript "gh" ''
    real_gh=${gh}/bin/gh
    case "''${1-} ''${2-}" in
      'pr create'|'pr new'|'pr edit') ;;
      *) exec "$real_gh" "$@" ;;
    esac

    operation=$2
    shift 2
    args=()
    body_kind=
    body_value=

    fail() {
      printf 'gh pr %s: %s\n' "$operation" "$1" >&2
      exit 1
    }

    while [ "$#" -gt 0 ]; do
      arg=$1
      shift
      flag=''${arg%%=*}
      case "$flag" in
        --help|-h) exec "$real_gh" pr "$operation" --help ;;
        --body|-b|--body-file|-F)
          [ -z "$body_kind" ] || fail 'Specify the description once.'
          body_kind=$flag
          if [ "$arg" = "$flag" ]; then
            [ "$#" -gt 0 ] || fail "$flag requires a value."
            body_value=$1
            shift
          else
            body_value=''${arg#*=}
          fi
          ;;
        --title|-t|--base|-B|--head|-H|--assignee|-a|--label|-l|--milestone|-m|--project|-p|--reviewer|-r|\
        --add-assignee|--add-label|--add-project|--add-reviewer|--remove-assignee|--remove-label|--remove-project|--remove-reviewer)
          args+=("$arg")
          if [ "$arg" = "$flag" ]; then
            [ "$#" -gt 0 ] || fail "$flag requires a value."
            args+=("$1")
            shift
          fi
          ;;
        --draft|-d|--dry-run|--no-maintainer-edit|--remove-milestone)
          args+=("$arg")
          ;;
        -*) fail "Unsupported option $flag. Run from the target checkout and supply the final description with --body or --body-file." ;;
        *://*) fail 'Use a PR number or branch in the target checkout.' ;;
        *) args+=("$arg") ;;
      esac
    done

    [ -z "''${GH_REPO:-}" ] || fail 'Unset GH_REPO and run from the target checkout.'
    if [ -z "$body_kind" ]; then
      [ "$operation" = edit ] || fail 'Supply the final description with --body or --body-file.'
      GH_PROMPT_DISABLED=1 exec "$real_gh" pr edit "''${args[@]}"
    fi

    set -e
    body=$(${pkgs.coreutils}/bin/mktemp)
    trap '${pkgs.coreutils}/bin/rm -f -- "$body"' EXIT
    case "$body_kind:$body_value" in
      --body-file:-|-F:-) ${pkgs.coreutils}/bin/cat > "$body" ;;
      --body-file:*|-F:*) ${pkgs.coreutils}/bin/cat -- "$body_value" > "$body" ;;
      *) printf '%s' "$body_value" > "$body" ;;
    esac

    ${checkClaudeAttribution} "$operation" "$body"
    GH_PROMPT_DISABLED=1 "$real_gh" pr "$operation" --body-file - "''${args[@]}" < "$body"
  '';
in
pkgs.symlinkJoin {
  name = "gh-${gh.version}-checked";
  inherit (gh) version meta;
  paths = [ gh ];
  postBuild = ''
    ln -s ${gh}/bin/gh "$out/bin/gh-unwrapped"
    rm "$out/bin/gh"
    ln -s ${wrapper} "$out/bin/gh"
  '';
}
