#!/bin/bash
# Installed only by this image builder's post-install package.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
[[ $EUID == 0 && $(uname -m) == x86_64 ]]
marker=/var/db/actions-vm-auto-bootstrap
if [[ ! -f "$marker" ]]; then
    ! id builder >/dev/null 2>&1 || { echo 'Refusing an existing builder account' >&2; exit 1; }
    touch "$marker"
fi
if ! id builder >/dev/null 2>&1; then
    uid=501
    while dscl . -list /Users UniqueID | awk '{print $2}' | grep -qx "$uid"; do uid=$((uid + 1)); done
    dscl . -create /Users/builder
    dscl . -create /Users/builder UniqueID "$uid"
    dscl . -create /Users/builder PrimaryGroupID 20
    dscl . -create /Users/builder NFSHomeDirectory /Users/builder
    dscl . -create /Users/builder UserShell /bin/bash
    dscl . -create /Users/builder RealName 'Temporary Image Builder'
    dscl . -create /Users/builder IsHidden 1
    dscl . -create /Users/builder Password '*'
fi
[[ $(dscl . -read /Users/builder NFSHomeDirectory) == 'NFSHomeDirectory: /Users/builder' ]]
! id -Gn builder | tr ' ' '\n' | grep -qx admin
install -d -o builder -g staff -m 0700 /Users/builder /Users/builder/.ssh
install -o builder -g staff -m 0600 /usr/local/share/actions-vm-image/builder.pub /Users/builder/.ssh/authorized_keys
install -d -m 0755 /etc/sudoers.d
printf '%s\n' 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/actions-vm-builder
chmod 0440 /etc/sudoers.d/actions-vm-builder
visudo -cf /etc/sudoers.d/actions-vm-builder
# Remote Login can be restricted to this access group on a fresh system.
if ! dscl . -read /Groups/com.apple.access_ssh >/dev/null 2>&1; then
    dseditgroup -o create com.apple.access_ssh
fi
dseditgroup -o edit -a builder -t user com.apple.access_ssh
pmset -a sleep 0 disksleep 0 displaysleep 0
touch /var/db/.AppleSetupDone
launchctl enable system/com.openssh.sshd
if ! launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
    launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist
fi
touch /var/db/actions-vm-bootstrap-ready
rm -f /Library/LaunchDaemons/org.actions-vm.image-firstboot.plist
echo 'ACTIONS_VM_BOOTSTRAP_READY'
