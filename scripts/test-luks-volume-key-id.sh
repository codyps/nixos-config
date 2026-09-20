#!/usr/bin/env bash
set -euo pipefail
# Public fixtures only. Regular image files require no root or device mapping.
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
printf %s public-test-password > "$work/password"
printf %s wrong-password > "$work/wrong-password"
printf %s 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$work/key"
for format in luks1 luks2; do
  image="$work/$format.img"
  truncate -s 32M "$image"
  cryptsetup luksFormat --batch-mode --type "$format" --key-size 512 \
    --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --volume-key-file "$work/key" \
    --uuid 11111111-2222-3333-4444-555555555555 --key-file "$work/password" "$image"
  before=$(sha256sum "$image")
  pin=$(luks-volume-key-id --device "$image" --name cryptroot --key-file "$work/password")
  test "$pin" = 77e740d9d987a52981ee75ae6ab327c2b70a8b49c6e36258abc426db85c5f831
  test "$(root-volume-key-id --device "$image" --key-file "$work/password")" = "$pin"
  other=$(luks-volume-key-id --device "$image" --name other --key-file "$work/password")
  test "$other" != "$pin"
  if luks-volume-key-id --device "$image" --name cryptroot --key-file "$work/wrong-password" > "$work/output"; then
    echo 'ERROR: accepted wrong password' >&2
    exit 1
  fi
  test ! -s "$work/output"
  test "$before" = "$(sha256sum "$image")"
done
# Explicit arguments prevent accidentally deriving a pin for the wrong mapper.
for argument in --device --name; do
  if luks-volume-key-id "$argument" placeholder > "$work/output" 2>/dev/null; then
    echo 'ERROR: accepted incomplete arguments' >&2
    exit 1
  fi
  test ! -s "$work/output"
done
truncate -s 32M "$work/plain.img"
if luks-volume-key-id --device "$work/plain.img" --name root --key-file "$work/password" > "$work/output"; then
  echo 'ERROR: accepted an unencrypted image' >&2
  exit 1
fi
test ! -s "$work/output"
luks-volume-key-id --help > /dev/null
root-volume-key-id --help > /dev/null
echo 'PASS: LUKS1/2 IDs, configured shortcut, mapper binding, invalid inputs, and unchanged images.'
