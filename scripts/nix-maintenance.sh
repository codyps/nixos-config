#!/usr/bin/env bash

readonly power_poll_seconds=5

child_pid=""
child_suspended=0

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

on_ac_power() {
  local power_status

  if ! power_status="$(/usr/bin/pmset -g batt 2>/dev/null)"; then
    return 1
  fi

  [[ "$power_status" == *"Now drawing from 'AC Power'"* ]]
}

wait_for_ac_power() {
  if on_ac_power; then
    return
  fi

  log "Waiting for AC power"
  until on_ac_power; do
    sleep "$power_poll_seconds"
  done
  log "AC power is available"
}

signal_child_group() {
  local signal="$1"

  [[ -n "$child_pid" ]] || return 1
  kill "-$signal" "-$child_pid" 2>/dev/null
}

# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
cleanup_child() {
  local exit_status=$?

  trap - EXIT
  if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
    signal_child_group CONT || true
    signal_child_group TERM || true
    wait "$child_pid" 2>/dev/null || true
  fi
  exit "$exit_status"
}

trap cleanup_child EXIT
trap 'exit 143' HUP INT TERM

run_while_on_ac_power() {
  local description="$1"
  local exit_status
  shift

  wait_for_ac_power
  log "Starting $description"

  # Monitor mode gives the child and its descendants a separate process group,
  # allowing the entire command to be suspended when AC power is disconnected.
  set -m
  "$@" &
  child_pid=$!
  set +m
  child_suspended=0

  while kill -0 "$child_pid" 2>/dev/null; do
    if on_ac_power; then
      if ((child_suspended)); then
        signal_child_group CONT || true
        child_suspended=0
        log "Resumed $description on AC power"
      fi
    elif ((!child_suspended)) && signal_child_group STOP; then
      child_suspended=1
      log "Suspended $description while on battery power"
    fi

    sleep "$power_poll_seconds"
  done

  if ((child_suspended)); then
    signal_child_group CONT || true
    child_suspended=0
  fi

  if wait "$child_pid"; then
    exit_status=0
  else
    exit_status=$?
  fi
  child_pid=""

  log "Finished $description with status $exit_status"
  return "$exit_status"
}

gc_status=0
if run_while_on_ac_power \
  "Nix garbage collection" \
  nix-collect-garbage --delete-older-than 30d; then
  gc_status=0
else
  gc_status=$?
fi

# Run optimisation after every completed GC attempt, even if GC reported an
# error. The power guard independently applies to this second phase.
optimise_status=0
if run_while_on_ac_power \
  "Nix store optimisation" \
  nix-store --optimise; then
  optimise_status=0
else
  optimise_status=$?
fi

if ((gc_status != 0)); then
  exit "$gc_status"
fi
exit "$optimise_status"
