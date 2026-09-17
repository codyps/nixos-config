#!/usr/bin/env bash
# Real systemd/libcryptsetup boundary test on disposable images. Run as root on Linux.
set -euo pipefail
work=$(mktemp -d /run/warbler-pin-test.XXXXXXXX)
mapper="warbler-pin-test-$$"
if [[ -e /dev/mapper/$mapper ]]; then
  rmdir "$work"
  echo "Test mapper already exists; refusing to touch it." >&2
  exit 1
fi
cleanup() {
  if [[ -e /dev/mapper/$mapper ]]; then
    systemd-cryptsetup detach "$mapper"
  fi
  rm -rf -- "$work"
}
trap cleanup EXIT
umask 077
printf %s warbler-public-test-password > "$work/password"
printf %s 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$work/key"
printf %s fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210 > "$work/other-key"
uuid=11111111-2222-3333-4444-555555555555
# This is the systemd volume-key identifier, not the LUKS header's PBKDF digest.
pin=$(python3 - "$mapper" "$uuid" "$work/key" <<'PY'
import hashlib, hmac, pathlib, sys
print(hmac.new(pathlib.Path(sys.argv[3]).read_bytes(),
               f'cryptsetup:{sys.argv[1]}:{sys.argv[2]}'.encode(), hashlib.sha256).hexdigest())
PY
)
for variant in genuine wrong-key wrong-uuid; do
  key="$work/key"
  image_uuid="$uuid"
  [[ $variant != wrong-key ]] || key="$work/other-key"
  [[ $variant != wrong-uuid ]] || image_uuid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
  image="$work/$variant.img"
  truncate -s 32M "$image"
  cryptsetup luksFormat --batch-mode --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
    --volume-key-file "$key" --uuid "$image_uuid" --key-file "$work/password" "$image"
  if [[ $variant == genuine ]]; then
    systemd-cryptsetup attach "$mapper" "$image" "$work/password" "luks,headless,fixate-volume-key=$pin"
    test -b "/dev/mapper/$mapper"
    systemd-cryptsetup detach "$mapper"
  else
    if systemd-cryptsetup attach "$mapper" "$image" "$work/password" "luks,headless,fixate-volume-key=$pin" > "$work/rejection.log" 2>&1; then
      echo "ERROR: accepted $variant" >&2
      exit 1
    fi
    # Reject for the pin mismatch, not an unrelated command or device failure.
    grep -q 'does not match the expectation' "$work/rejection.log"
    test ! -e "/dev/mapper/$mapper"
  fi
done
printf '%s\n' 'PASS: genuine recovery accepted; substituted key and UUID rejected before mapping.'
