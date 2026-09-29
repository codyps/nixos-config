#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
[[ $EUID == 0 && $(uname -m) == x86_64 ]]
bundle=$1
# Apple-supplied artifacts are provided by the operator, never an Apple account.
if [[ -f "$bundle/toolchain.xip" ]]; then
    [[ ! -e /Applications/Xcode.app ]] || { echo 'Xcode already exists; use a fresh image for replacement.' >&2; exit 1; }
    (cd "$bundle" && xip --expand toolchain.xip)
    mv "$bundle/Xcode.app" /Applications/Xcode.app
    xcode-select --switch /Applications/Xcode.app/Contents/Developer
    xcodebuild -license accept
    xcodebuild -runFirstLaunch
elif [[ -f "$bundle/toolchain.pkg" ]]; then
    pkgutil --check-signature "$bundle/toolchain.pkg"
    installer -pkg "$bundle/toolchain.pkg" -target /
    xcode-select --switch /Library/Developer/CommandLineTools
elif [[ -f "$bundle/install-clt" ]]; then
    if ! pkgutil --pkg-info com.apple.pkg.CLTools_Executables >/dev/null 2>&1; then
        # The install-on-demand marker is also used by Homebrew's installer.
        placeholder=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
        [[ ! -e "$placeholder" ]] || { echo 'Another CLT installation is pending.' >&2; exit 1; }
        touch "$placeholder"
        trap 'rm -f "$placeholder"' EXIT
        softwareupdate --list > "$bundle/softwareupdate.txt" 2>&1
        label=$(sed -n 's/^.*Label: \(Command Line Tools.*\)$/\1/p' "$bundle/softwareupdate.txt" | grep -vi beta | LC_ALL=C sort -V | tail -n 1 || true)
        [[ -n "$label" ]] || { cat "$bundle/softwareupdate.txt" >&2; echo 'No compatible CLT package offered by Apple.' >&2; exit 1; }
        softwareupdate --install "$label" --verbose
        rm -f "$placeholder"
        trap - EXIT
    fi
    xcode-select --switch /Library/Developer/CommandLineTools
    pkgutil --pkg-info com.apple.pkg.CLTools_Executables
fi
xcode-select -p >/dev/null
if ! id runner >/dev/null 2>&1; then
    uid=501
    while dscl . -list /Users UniqueID | awk '{print $2}' | grep -qx "$uid"; do uid=$((uid + 1)); done
    dscl . -create /Users/runner
    dscl . -create /Users/runner UniqueID "$uid"
    dscl . -create /Users/runner PrimaryGroupID 20
    dscl . -create /Users/runner NFSHomeDirectory /Users/runner
    dscl . -create /Users/runner UserShell /bin/bash
    dscl . -create /Users/runner RealName 'GitHub Actions Runner'
    dscl . -create /Users/runner IsHidden 1
    dscl . -create /Users/runner Password '*'
fi
[[ $(dscl . -read /Users/runner NFSHomeDirectory) == 'NFSHomeDirectory: /Users/runner' ]]
! id -Gn runner | tr ' ' '\n' | grep -qx admin
install -d -o runner -g staff -m 0755 /Users/runner /Users/runner/actions-runner
[[ ! -e /Users/runner/actions-runner/.runner ]] || { echo 'Runner already registered' >&2; exit 1; }
tar -xzf "$bundle/runner.tar.gz" -C /Users/runner/actions-runner
chown -R runner:staff /Users/runner/actions-runner
install -d -o root -g wheel -m 0755 /usr/local/libexec
install -o root -g wheel -m 0755 "$bundle/bootstrap.sh" /usr/local/libexec/actions-vm-bootstrap
install -o root -g wheel -m 0755 "$bundle/runner.sh" /usr/local/libexec/actions-vm-runner
# Install launchd configuration only at seal time, to allow preparation reboots.
install -o root -g wheel -m 0644 "$bundle/org.actions-vm.bootstrap.plist" /usr/local/libexec/org.actions-vm.bootstrap.plist
pmset -a sleep 0 disksleep 0 displaysleep 0
softwareupdate --schedule off
defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
touch /var/db/actions-vm-provisioned
