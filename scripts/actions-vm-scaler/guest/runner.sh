#!/bin/bash
# Install root:wheel, mode 0755, at /usr/local/libexec/actions-vm-runner.
set -euo pipefail
export HOME=/Users/runner
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin
if [[ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
    source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi
export ACTIONS_RUNNER_INPUT_JITCONFIG
ACTIONS_RUNNER_INPUT_JITCONFIG=$(cat "$HOME/.jitconfig")
rm "$HOME/.jitconfig"
cd "$HOME/actions-runner"
exec ./run.sh
