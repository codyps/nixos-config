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

if [[ "${1-}" = foreground ]]; then
  # systemd owns this process directly. No detached daemon or native updater:
  # the user timer installs packages and asks systemd for an unbounded drain.
  current="$CODEX_HOME/packages/app-server-daemon/current"
  if [[ ! -e "$current" && ! -L "$current" ]]; then
    current="$CODEX_HOME/packages/standalone/current"
  fi
  codex="$current/bin/codex"
  if [[ ! -x "$codex" ]]; then codex="$current/codex"; fi
  exec "$codex" app-server --remote-control --listen unix:// --managed-daemon
fi

# Both detached children inherit the systemd unit's UID, cgroup, and sandbox.
# Let Codex select its daemon package and manage updater eligibility. A pinned
# release or disabled updates legitimately has no updater process. Lifecycle
# failures must not make systemd kill otherwise healthy sessions.
until managed_codex app-server daemon bootstrap --remote-control; do
  echo 'Codex bootstrap failed; retrying in 30 seconds.' >&2
  sleep 30
done
while sleep 30; do
  # Native start repairs a missing eligible updater, but leaves a running
  # server alone. In particular, it is not a request to upgrade that server.
  if ! managed_codex app-server daemon start >/dev/null; then
    echo 'Codex health check failed; leaving existing processes intact and retrying.' >&2
  fi
done
