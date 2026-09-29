#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
[[ $EUID == 0 && -f /var/db/actions-vm-provisioned ]]
builder=$2
cd /private/tmp
[[ "$builder" == builder ]] || { echo 'Seal requires the disposable builder account, not a personal account.' >&2; exit 1; }
[[ -x /Users/runner/actions-runner/run.sh ]]
for path in .runner .credentials .credentials_rsaparams _work; do
    [[ ! -e /Users/runner/actions-runner/$path ]] || { echo "Unexpected runner state: $path" >&2; exit 1; }
done
xcode-select -p
if [[ $1 == xcode ]]; then
    xcodebuild -license accept
    xcodebuild -runFirstLaunch
    xcodebuild -version
else
    pkgutil --pkg-info com.apple.pkg.CLTools_Executables
fi
sudo -H -u runner /Users/runner/actions-runner/bin/Runner.Listener --version
sudo -H -u runner /usr/bin/xcrun clang --version
sudo -H -u runner /usr/bin/xcrun swift --version
# Exercise SDK lookup, compilation, linking, and execution as the job user.
sudo -H -u runner /bin/bash <<'CHECK'
set -euo pipefail
scratch=$(mktemp -d /private/tmp/actions-compiler.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
printf '%s\n' '#include <stdio.h>' 'int main(void) { puts("clang-ok"); return 0; }' > "$scratch/main.c"
xcrun clang "$scratch/main.c" -o "$scratch/clang-check"
[[ $("$scratch/clang-check") == clang-ok ]]
printf '%s\n' 'print("swift-ok")' > "$scratch/main.swift"
xcrun swiftc "$scratch/main.swift" -o "$scratch/swift-check"
[[ $("$scratch/swift-check") == swift-ok ]]
echo 'Compiler smoke tests: C and Swift passed as runner'
CHECK
if [[ -f /var/db/actions-vm-auto-bootstrap ]]; then
    # The package-created account has no password, secure token or admin group.
    [[ $(dscl . -read /Users/builder Password) == 'Password: *' ]]
    ! id -Gn builder | tr ' ' '\n' | grep -qx admin
    # macOS can reject deletion even without a secure token. Revoke all login
    # paths instead of depending on deleting the currently authenticated user.
    dscl . -create /Users/builder UserShell /usr/bin/false
    dscl . -create /Users/builder IsHidden 1
    dseditgroup -o edit -d builder -t user com.apple.access_ssh
    [[ $(dscl . -read /Users/builder UserShell) == 'UserShell: /usr/bin/false' ]]
    ! id -Gn builder | tr ' ' '\n' | grep -qx com.apple.access_ssh
    echo 'Builder shell and SSH access revoked; non-admin account record retained'
else
    # Console-created accounts can be the last protected secure-token admin.
    if [[ ! -f /var/db/actions-vm-builder-password-revoked ]]; then
        dscl . -passwd /Users/builder "${builder_password:?builder password required}" "$(uuidgen)$(uuidgen)"
        touch /var/db/actions-vm-builder-password-revoked
    fi
    pwpolicy -u builder -disableuser
    dscl . -create /Users/builder UserShell /usr/bin/false
    dscl . -create /Users/builder IsHidden 1
fi
unset builder_password
rm -f /Library/LaunchDaemons/org.actions-vm.image-firstboot.plist
rm -f /usr/local/libexec/actions-vm-image-firstboot
rm -rf /usr/local/share/actions-vm-image
# Remove authorized keys from all home directories before publishing.
for home in /Users/* /var/root; do
    if [[ -d "$home/.ssh" ]]; then rm -f "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; fi
done
# TCC protects generated Library/Photos folders even from root over SSH. The
# setup account must contain no personal data. Remove build state and make its
# remaining OS-generated template home inaccessible to the job user.
rm -rf /Users/builder/.ssh /Users/builder/.bash_sessions /Users/builder/.zsh_sessions
rm -f /Users/builder/.bash_history /Users/builder/.zsh_history
chown root:wheel /Users/builder
chmod 0700 /Users/builder
rm -f /private/tmp/access.sh
rm -f /etc/sudoers.d/actions-vm-builder
rm -f /etc/ssh/ssh_host_*
# Install only after cleanup succeeds; loading it now would wait for a job seed.
install -o root -g wheel -m 0644 /usr/local/libexec/org.actions-vm.bootstrap.plist /Library/LaunchDaemons/
sw_vers
echo ACTIONS_VM_IMAGE_SEALED
# Let SSH deliver the receipt before shutdown closes its transport.
nohup /bin/sh -c 'sleep 3; /sbin/shutdown -h now' >/dev/null 2>&1 &
