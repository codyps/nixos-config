#!/bin/bash
set -euo pipefail
umask 077

if (( $# == 0 )); then
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/bin
    export RUNNER_MANUALLY_TRAP_SIG=1
    cd /opt/actions-runner
    set -- ./run.sh
fi

seed="${RUNTIME_DIRECTORY:?}/seed"
install -d -m 0700 "$seed"
for ((attempt = 0; attempt < 60; attempt++)); do
    if mount -t iso9660 -o ro,nosuid,nodev,noexec LABEL=RUNNER_SEED "$seed" 2>/dev/null; then
        break
    fi
    sleep 1
done
if [[ ! -s "$seed/jitconfig" ]]; then
    echo 'RUNNER_SEED is missing or has no JIT configuration' >&2
    exit 1
fi
ACTIONS_RUNNER_INPUT_JITCONFIG=$(<"$seed/jitconfig")
umount "$seed"
export ACTIONS_RUNNER_INPUT_JITCONFIG
exec runuser -u runner -- "$@"
