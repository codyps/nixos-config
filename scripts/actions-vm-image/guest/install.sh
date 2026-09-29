#!/bin/bash
# Run only in Recovery Terminal with this builder's private virtual disk attached.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
expected=$(cat /Volumes/IMAGE_BUILD/disk-bytes)
selected=()
for disk in $(diskutil list | awk '/^\/dev\/disk[0-9]+ / {print $1}'); do
    info=$(diskutil info -plist "$disk")
    size=$(printf '%s' "$info" | plutil -extract TotalSize raw -o - - 2>/dev/null || true)
    whole=$(printf '%s' "$info" | plutil -extract WholeDisk raw -o - - 2>/dev/null || true)
    if [[ "$size" == "$expected" && "$whole" == true ]]; then
        selected+=("$disk")
    fi
done
[[ ${#selected[@]} == 1 ]] || { echo 'Expected exactly one builder-sized whole disk; refusing to erase.' >&2; exit 1; }
# The host controls all attached disks; only macos.qcow2 is writable.
installer=(/Install\ macOS*.app/Contents/Resources/startosinstall)
[[ ${#installer[@]} == 1 && -x "${installer[0]}" ]] || { echo 'Recovery does not contain startosinstall; use the graphical installer.' >&2; exit 1; }
# Refuse repeating the destructive initial install against an installed volume.
[[ ! -d /Volumes/MACOS/System && ! -d '/Volumes/MACOS - Data' ]] || { echo 'Existing installation detected; refusing to erase.' >&2; exit 1; }
extra=()
if [[ -f /Volumes/IMAGE_BUILD/bootstrap.pkg ]]; then
    extra=(--installpackage /Volumes/IMAGE_BUILD/bootstrap.pkg)
fi
diskutil eraseDisk APFS MACOS GPT "${selected[0]}"
exec "${installer[0]}" --agreetolicense --volume /Volumes/MACOS --nointeraction "${extra[@]}"
