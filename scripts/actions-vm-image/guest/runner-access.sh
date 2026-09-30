#!/bin/bash
# Run in macOS Recovery against the offline Data volume before sealing.
# GitHub's macOS image also grants SystemPolicyAllFiles to its shell/runner:
# https://github.com/actions/runner-images/blob/main/images/macos/scripts/build/configure-tccdb-macos.sh
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
[[ $EUID == 0 && $# == 1 ]]
data=$1
test -x "$data/Users/runner/actions-runner/bin/Runner.Listener"
db="$data/Library/Application Support/com.apple.TCC/TCC.db"
test -f "$db"
# Recovery omits the sqlite3 CLI; use the matching installed system's binary.
sqlite=/usr/bin/sqlite3
if [[ ! -x "$sqlite" ]]; then sqlite="${data% - Data}/usr/bin/sqlite3"; fi
test -x "$sqlite"
for client in /bin/bash /usr/local/libexec/actions-vm-bootstrap /usr/local/libexec/actions-vm-runner /Users/runner/actions-runner/bin/Runner.Listener /Users/runner/actions-runner/bin/Runner.Worker; do
    "$sqlite" "$db" "INSERT OR REPLACE INTO access
      (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier,last_modified)
      VALUES ('kTCCServiceSystemPolicyAllFiles','$client',1,2,4,1,'UNUSED',strftime('%s','now'));"
done
[[ $("$sqlite" "$db" 'PRAGMA integrity_check;') == ok ]]
