set -euo pipefail

export CODEX_INSTALL_DIR="$HOME/.local/share/codex-bin"
export CODEX_NON_INTERACTIVE=1
export PATH="$CODEX_INSTALL_DIR:$PATH"
installer=$(mktemp)
trap 'rm -f "$installer"' EXIT
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --connect-timeout 30 --max-time 120 \
  https://chatgpt.com/codex/install.sh -o "$installer"

# Update CLI and server packages independently, respecting an explicit pin.
# The installer checks the selection again while holding its installation lock.
for package in standalone app-server-daemon; do
  root="$CODEX_HOME/packages/$package"
  export CODEX_INSTALL_DAEMON_ONLY=0
  if [[ "$package" = app-server-daemon ]]; then export CODEX_INSTALL_DAEMON_ONLY=1; fi
  export CODEX_RELEASE=latest
  export CODEX_INSTALL_IF_LATEST=0
  export CODEX_UPDATE_FROM_RELEASE=""
  if [[ -e "$root/current" || -L "$root/current" ]]; then
    if [[ ! -s "$root/auto-update-version" ]]; then
      echo "Skipping pinned $package package."
      continue
    fi
    CODEX_UPDATE_FROM_RELEASE=$(basename "$(readlink -e "$root/current")")
    export CODEX_INSTALL_IF_LATEST=1
  fi
  sh "$installer"
done

# Comparing with the running executable also catches out-of-band updates and
# retries a previously failed reload. Only systemd signals the current MainPID.
if systemctl --user is-active --quiet codex-ai.service; then
  current="$CODEX_HOME/packages/app-server-daemon/current"
  if [[ ! -e "$current" && ! -L "$current" ]]; then current="$CODEX_HOME/packages/standalone/current"; fi
  codex="$current/bin/codex"
  if [[ ! -x "$codex" ]]; then codex="$current/codex"; fi
  pid=$(systemctl --user show codex-ai.service --property=MainPID --value)
  running=$(readlink -e "/proc/$pid/exe")
  selected=$(readlink -e "$codex")
  if [[ "$running" != "$selected" ]]; then
    echo 'Codex update installed; draining active turns before replacement.'
    systemctl --user reload codex-ai.service
  fi
fi
