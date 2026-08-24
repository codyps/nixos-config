#!/usr/bin/env bash

readonly shizuku_package="moe.shizuku.privileged.api"
readonly shizuku_start_script="/sdcard/Android/data/${shizuku_package}/start.sh"
readonly reconnect_delay_seconds=1

connected_devices=()

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

shizuku_is_running() {
  local serial="$1"

  adb -s "$serial" shell pidof shizuku_server >/dev/null 2>&1
}

device_was_connected() {
  local serial="$1"
  local connected_serial

  for connected_serial in "${connected_devices[@]}"; do
    if [[ "$connected_serial" == "$serial" ]]; then
      return 0
    fi
  done

  return 1
}

start_shizuku_if_needed() {
  local serial="$1"
  local package_path
  local start_output

  if shizuku_is_running "$serial"; then
    log "Shizuku is already running on $serial"
    return
  fi

  package_path="$(adb -s "$serial" shell pm path "$shizuku_package" 2>/dev/null || true)"
  if [[ "$package_path" != package:* ]]; then
    log "Shizuku is not installed or is unavailable on $serial"
    return
  fi

  log "Starting Shizuku on $serial"
  if ! start_output="$(adb -s "$serial" shell sh "$shizuku_start_script" 2>&1)"; then
    log "Shizuku start command failed on $serial: $start_output"
    return
  fi

  for _ in {1..5}; do
    if shizuku_is_running "$serial"; then
      log "Shizuku started successfully on $serial"
      return
    fi
    sleep 1
  done

  log "Shizuku did not start on $serial: $start_output"
}

watch_device_events() {
  local frame_length_hex
  local frame_length
  local snapshot
  local serial
  local state
  local details
  local -a current_devices=()

  while IFS= read -r -N 4 frame_length_hex; do
    if [[ ! "$frame_length_hex" =~ ^[[:xdigit:]]{4}$ ]]; then
      log "ADB device tracker returned an invalid frame length: $frame_length_hex"
      return 1
    fi

    frame_length=$((16#$frame_length_hex))
    snapshot=""
    if ((frame_length > 0)) && ! IFS= read -r -N "$frame_length" snapshot; then
      log "ADB device tracker disconnected during a device-list update"
      return 1
    fi

    current_devices=()
    while IFS=$'\t ' read -r serial state details; do
      if [[ "$state" == "device" && " $details " == *" usb:"* ]]; then
        current_devices+=("$serial")
      fi
    done <<<"$snapshot"

    for serial in "${current_devices[@]}"; do
      if ! device_was_connected "$serial"; then
        start_shizuku_if_needed "$serial"
      fi
    done

    connected_devices=("${current_devices[@]}")
  done < <(adb track-devices -l 2>/dev/null)

  return 1
}

log "Watching for Android USB device events"

while true; do
  if ! watch_device_events; then
    log "ADB device tracker stopped; reconnecting in ${reconnect_delay_seconds}s"
  fi

  sleep "$reconnect_delay_seconds"
done
