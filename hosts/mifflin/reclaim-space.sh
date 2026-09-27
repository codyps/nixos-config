#!/usr/bin/env bash
# Run only against an offline ext4 filesystem. The initrd unit owns root fsck.
set -euo pipefail

fail() {
  printf 'reclaim-space: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 2 ]] || fail 'Expected root device, filesystem UUID, and optional swap devices.'
root_device=$1
expected_uuid=$2
shift 2

[[ -b "$root_device" ]] || fail "Not a block device: $root_device"
[[ $(blkid -p -s TYPE -o value "$root_device") == ext4 ]] || fail 'Root is not ext4.'
[[ $(blkid -p -s UUID -o value "$root_device") == "$expected_uuid" ]] || fail 'Root UUID does not match.'

# Compare device numbers, not mount source names: mounts can use other aliases.
device_number=$(lsblk -dnro MAJ:MIN "$root_device")
[[ $device_number =~ ^[0-9]+:[0-9]+$ ]] || fail 'Cannot identify root device number.'
if awk -v device="$device_number" '$3 == device { found = 1 } END { exit !found }' /proc/self/mountinfo; then
  fail 'Root is mounted; refusing to zero it.'
fi
if awk 'NR > 1 { found = 1 } END { exit !found }' /proc/swaps; then
  fail 'Swap is active; maintenance must run before swap activation.'
fi
for swap_device in "$@"; do
  [[ -b "$swap_device" ]] || fail "Missing swap partition: $swap_device"
  # A hibernation image changes the swap signature. Never overwrite it or
  # modify its root filesystem by booting the maintenance entry with noresume.
  [[ $(blkid -p -s TYPE -o value "$swap_device") == swap ]] ||
    fail "Swap is not clean swap (possibly a hibernation image): $swap_device"
done

[[ $(vmware-rpctool disk.wiper.enable) == 1 ]] || fail 'Fusion does not enable disk compaction.'

printf 'reclaim-space: checking %s before zeroing free blocks\n' "$root_device"
fsck_status=0
e2fsck -f -p "$root_device" || fsck_status=$?
case $fsck_status in
  0|1) ;;
  *) fail "Filesystem check returned $fsck_status; no zeroing or compaction was attempted." ;;
esac

printf 'reclaim-space: zeroing unallocated blocks without creating files\n'
zerofree -v "$root_device" || fail 'Zeroing failed; compaction was not attempted.'
# Flush the block-device file and its backing storage before asking the host
# to scan for zero grains. sync -f uses syncfs, which is not suitable here.
sync "$root_device" || fail 'Flush failed; compaction was not attempted.'

printf 'reclaim-space: zeroing finished; asking Fusion to compact all eligible disks\n'
vmware-rpctool disk.shrink || fail 'Zeroing completed, but Fusion compaction failed.'
printf 'reclaim-space: Fusion compaction completed; continuing normal boot\n'
