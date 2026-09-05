#!/usr/bin/env bash

# CARGO_WRAPPER_REAL_CARGO and CARGO_WRAPPER_DEFAULT_CACHE_SUBDIRECTORY are
# supplied by the Home Manager package. Keeping the implementation here makes
# the wrapper testable without depending on a particular Nix store path.

real_cargo=${CARGO_WRAPPER_REAL_CARGO:?}
default_cache_subdirectory=${CARGO_WRAPPER_DEFAULT_CACHE_SUBDIRECTORY:?}
default_cache_home=${HOME:?}/$default_cache_subdirectory

toolchain_args=()
cargo_prefix_args=()
metadata_args=()
args=("$@")
has_target_dir=false
cargo_subcommand=
cargo_subcommand_index=-1

if (( ${#args[@]} > 0 )) && [[ ${args[0]} == +* ]]; then
  toolchain_args+=("${args[0]}")
fi

# Find the actual Cargo subcommand, accounting for Cargo's global options.
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    +*)
      if (( i == 0 )); then
        continue
      fi
      ;;
    -C)
      if (( i + 1 < ${#args[@]} )); then
        cargo_prefix_args+=("${args[i]}" "${args[i + 1]}")
      fi
      ((i += 1))
      continue
      ;;
    -C?*)
      cargo_prefix_args+=("${args[i]}")
      continue
      ;;
    --config|--color|--explain|--manifest-path|--target-dir|-m|-Z)
      ((i += 1))
      continue
      ;;
    --)
      break
      ;;
    -*)
      continue
      ;;
    *)
      cargo_subcommand=${args[i]}
      cargo_subcommand_index=$i
      break
      ;;
  esac
done

has_subcommand_argument() {
  local wanted=$1
  local argument

  for ((i = cargo_subcommand_index + 1; i < ${#args[@]}; i++)); do
    argument=${args[i]}
    [[ $argument == -- ]] && break
    if [[ $argument == "$wanted" || $argument == "$wanted="* ]]; then
      return 0
    fi
  done
  return 1
}

subcommand_option_value() {
  local wanted=$1
  local argument

  for ((i = cargo_subcommand_index + 1; i < ${#args[@]}; i++)); do
    argument=${args[i]}
    [[ $argument == -- ]] && break
    if [[ $argument == "$wanted="* ]]; then
      printf '%s\n' "${argument#*=}"
      return 0
    fi
    if [[ $argument == "$wanted" ]] && (( i + 1 < ${#args[@]} )); then
      printf '%s\n' "${args[i + 1]}"
      return 0
    fi
  done
  return 1
}

find_nested_subcommand() {
  local argument
  local j

  for ((j = cargo_subcommand_index + 1; j < ${#args[@]}; j++)); do
    argument=${args[j]}
    case $argument in
      --config|--color|--manifest-path|--target-dir|-C|-m|-Z)
        ((j += 1))
        ;;
      --)
        break
        ;;
      -*)
        ;;
      *)
        printf '%s\n' "$argument"
        return 0
        ;;
    esac
  done
  return 1
}

# Preserve options which can change the selected workspace, Cargo
# configuration, or whether resolving workspace metadata may access the
# network. Other command-specific options do not apply to `cargo metadata`.
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    --)
      break
      ;;
    --target-dir)
      has_target_dir=true
      ((i += 1))
      ;;
    --target-dir=*)
      has_target_dir=true
      ;;
    --manifest-path|--config|-m|-Z)
      if (( i + 1 < ${#args[@]} )); then
        metadata_args+=("${args[i]}" "${args[i + 1]}")
        ((i += 1))
      fi
      ;;
    --manifest-path=*|--config=*|-m?*|-Z?*)
      metadata_args+=("${args[i]}")
      ;;
    --locked|--offline|--frozen)
      metadata_args+=("${args[i]}")
      ;;
  esac
done

# An explicit target directory is not Cargo's default, even if it happens to
# have the same spelling. Let Cargo interpret it without intervention.
if [[ -v CARGO_TARGET_DIR || $has_target_dir == true ]]; then
  exec "$real_cargo" "$@"
fi

# Only commands which use the workspace target are allowed to install the
# link. Commands such as metadata, tree, fmt, registry/Git installs, dependency
# management, and registry management must remain completely transparent.
target_action=none
nested_subcommand=$(find_nested_subcommand || true)
workspace_manifest_override=
case $cargo_subcommand in
  b|bench|build|c|check|clippy|d|doc|expand|fix|package|publish|r|run|rustc|rustdoc|t|test)
    target_action=create
    ;;
  clean)
    target_action=clean
    ;;
  embed|flash)
    # probe-rs builds by default, but a supplied artifact bypasses Cargo.
    if ! has_subcommand_argument --path; then
      target_action=create
      if work_dir=$(subcommand_option_value --work-dir); then
        workspace_manifest_override="$work_dir/Cargo.toml"
      fi
    fi
    ;;
  install)
    # Registry and Git installs use a temporary target. A local path install
    # uses the target belonging to the selected local workspace.
    if install_path=$(subcommand_option_value --path); then
      target_action=create
      workspace_manifest_override="$install_path/Cargo.toml"
    fi
    ;;
  miri)
    # `cargo miri setup` and bare `cargo miri` do not use the workspace target.
    case $nested_subcommand in
      bench|nextest|run|test)
        target_action=create
        ;;
    esac
    ;;
  mommy)
    # cargo-mommy delegates to the Cargo command passed after it.
    case $nested_subcommand in
      clean)
        target_action=clean
        ;;
      b|bench|build|c|check|clippy|d|doc|fix|package|publish|r|run|rustc|rustdoc|t|test)
        target_action=create
        ;;
    esac
    ;;
  lbench|lbuild|lcheck|lclippy|ldoc|lfix|llbench|llbuild|llcheck|llclippy|lldoc|llfix|llrun|llrustc|llrustdoc|lltest|lrun|lrustc|lrustdoc|ltest)
    # cargo-limit frontends for the corresponding build commands.
    target_action=create
    ;;
esac

if [[ $cargo_subcommand == expand ]] && has_subcommand_argument --themes; then
  target_action=none
fi

# Help/version modes never execute the selected subcommand.
if [[ $target_action == none ]] \
  || has_subcommand_argument -h \
  || has_subcommand_argument --help \
  || has_subcommand_argument -V \
  || has_subcommand_argument --version; then
  exec "$real_cargo" "$@"
fi

probe_metadata_args=("${metadata_args[@]}")
if [[ -n $workspace_manifest_override ]]; then
  probe_metadata_args+=(--manifest-path "$workspace_manifest_override")
fi

# Locating the workspace is substantially cheaper than collecting metadata.
# In the steady state, the target symlink already exists and this is the only
# probe the wrapper needs.
if ! manifest_path="$("$real_cargo" "${toolchain_args[@]}" \
  "${cargo_prefix_args[@]}" locate-project \
  --workspace --message-format plain "${probe_metadata_args[@]}" 2>/dev/null)"; then
  exec "$real_cargo" "$@"
fi

cache_home=${XDG_CACHE_HOME:-$default_cache_home}
candidate_target="$(dirname "$manifest_path")/target"
managed_link_target=
if [[ -L $candidate_target ]]; then
  link_target=$(readlink "$candidate_target")
  [[ $link_target == /* ]] || link_target="$(dirname "$candidate_target")/$link_target"
  link_target=$(realpath -m -- "$link_target")
  for cache_base in "$cache_home/cargo-targets" "$default_cache_home/cargo-targets"; do
    if [[ $(dirname "$link_target") == "$(realpath -m -- "$cache_base")" ]]; then
      managed_link_target=$link_target
    fi
  done
fi
if [[ $target_action == clean && ! -L $candidate_target ]]; then
  exec "$real_cargo" "$@"
fi
if [[ $target_action != clean \
  && ( -e $candidate_target || ( -L $candidate_target && -z $managed_link_target ) ) ]]; then
  exec "$real_cargo" "$@"
fi

# Ask Cargo for its effective target directory before intervening. This keeps
# CARGO_TARGET_DIR and build.target-dir configurations authoritative.
if ! metadata="$("$real_cargo" "${toolchain_args[@]}" \
  "${cargo_prefix_args[@]}" metadata --no-deps \
  --format-version 1 "${probe_metadata_args[@]}" 2>/dev/null)"; then
  exec "$real_cargo" "$@"
fi

if ! workspace_root="$(jq -er '.workspace_root' <<<"$metadata")" \
  || ! target_directory="$(jq -er '.target_directory' <<<"$metadata")"; then
  exec "$real_cargo" "$@"
fi

default_target="$workspace_root/target"
if [[ $target_directory != "$default_target" \
  || ( $target_action != clean \
    && ( -e $default_target || ( -L $default_target && -z $managed_link_target ) ) ) ]]; then
  exec "$real_cargo" "$@"
fi

# Escape literal dashes before flattening separators so the mapping stays
# unambiguous: /a-b/c becomes -a--b-c, while /a/b-c becomes -a-b--c.
workspace_cache_key=${workspace_root//-/--}
workspace_cache_key=${workspace_cache_key//\//-}
cache_target="$cache_home/cargo-targets/$workspace_cache_key"

# Keep existing managed links working across cache naming changes. Only repair
# after Cargo confirms this invocation uses its default workspace target.
if [[ -n $managed_link_target ]]; then
  cache_target=$managed_link_target
  if [[ $target_action != clean ]]; then
    mkdir -p -- "$cache_target"
    exec "$real_cargo" "$@"
  fi
fi

if [[ $target_action == clean ]]; then
  if [[ -z $managed_link_target ]]; then
    exec "$real_cargo" "$@"
  fi

  if CARGO_TARGET_DIR=$cache_target "$real_cargo" "$@"; then
    clean_status=0
  else
    clean_status=$?
  fi

  # A full clean removes the cache directory, leaving the workspace link
  # dangling. Selective and dry-run cleans retain both.
  if [[ -L $default_target && ! -e $default_target ]] \
    && ! has_subcommand_argument --dry-run; then
    rm "$default_target"
  fi
  exit "$clean_status"
fi

mkdir -p "$cache_target"
if ! ln -s "$cache_target" "$default_target"; then
  # Another Cargo process may have won the race. Accept any target it created,
  # but do not hide an actual failure to install the link.
  if [[ ! -e $default_target && ! -L $default_target ]]; then
    printf 'cargo wrapper: could not create target link at %s\n' \
      "$default_target" >&2
    exit 1
  fi
fi

exec "$real_cargo" "$@"
