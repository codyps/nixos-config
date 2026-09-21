set -euo pipefail

# The installer/updater owns this mutable standalone tree. Keep its bin directory
# on the service PATH so the installer does not edit the SSH login profile.
export CODEX_INSTALL_DIR="$HOME/.local/share/codex-bin"
export CODEX_NON_INTERACTIVE=1
export PATH="$CODEX_INSTALL_DIR:$PATH"
managed_codex() {
  local current="$CODEX_HOME/packages/standalone/current"
  if [[ -x "$current/bin/codex" ]]; then
    "$current/bin/codex" "$@"
  else
    "$current/codex" "$@"
  fi
}

if [[ ! -x "$CODEX_HOME/packages/standalone/current/bin/codex" &&
      ! -x "$CODEX_HOME/packages/standalone/current/codex" ]]; then
  installer=$(mktemp)
  trap 'rm -f "$installer"' EXIT
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 30 --max-time 120 \
    https://chatgpt.com/codex/install.sh -o "$installer"
  sh "$installer"
  rm -f "$installer"
  trap - EXIT
fi

# Both detached children inherit the systemd unit's UID, cgroup, and sandbox.
# Bootstrap re-establishes Codex's updater on every boot/service restart.
managed_codex app-server daemon bootstrap --remote-control
while sleep 30; do
  # Idempotent health check/start also picks up the current managed binary.
  managed_codex app-server daemon start >/dev/null
  updater_pid=$(jq -er '.pid | select(type == "number" and . > 1)' \
    "$CODEX_HOME/app-server-daemon/app-server-updater.pid")
  # If the updater dies, let systemd restart the whole group and bootstrap it.
  kill -0 "$updater_pid"
done
