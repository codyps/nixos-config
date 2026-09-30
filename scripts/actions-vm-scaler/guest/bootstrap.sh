#!/bin/bash
# Install root:wheel, mode 0755, at /usr/local/libexec/actions-vm-bootstrap.
# Golden image contract: local `runner` with guest sudo, /Users/runner/actions-runner.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077
trap '/sbin/shutdown -h now' EXIT

# Disk Arbitration may not mount removable media without a GUI login.
for ((attempt=0; attempt<120; attempt++)); do
    if [[ -f /Volumes/RUNNER_SEED/jitconfig ]]; then break; fi
    device=$(diskutil list | awk '/RUNNER_SEED/ {print $NF; exit}')
    if [[ "$device" =~ ^disk[0-9]+(s[0-9]+)*$ ]]; then
        diskutil mount readOnly "$device" >/dev/null 2>&1 || true
    fi
    sleep 1
done
test -s /Volumes/RUNNER_SEED/jitconfig
test -x /Users/runner/actions-runner/run.sh
install -o runner -g staff -m 0400 /Volumes/RUNNER_SEED/jitconfig /Users/runner/.jitconfig
diskutil unmount /Volumes/RUNNER_SEED >/dev/null

# The runner consumes JIT configuration from its environment, as in the official
# scaleset example. Neither the controller App key nor any PAT reaches the VM.
sudo -H -u runner /usr/local/libexec/actions-vm-runner
