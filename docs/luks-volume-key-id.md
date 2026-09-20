# LUKS volume-key identity

On Linux, obtain the public ID used by systemd's `fixate-volume-key=` option:

```sh
sudo nix run path:.#luks-volume-key-id -- --device /dev/nvme0n1p2 --name cryptroot
```

Both arguments are required. `--device` accepts any LUKS1 or LUKS2 device path
(including `/dev/disk/by-uuid/...` or `/dev/disk/by-id/...`) or image file.
Point it at the encrypted container, not the decrypted `/dev/mapper/...` device.
`--name` is the target mapper name from the first column of crypttab, without
the `/dev/mapper/` prefix. Names containing letters, digits, underscores, dots,
and hyphens are supported. The name is part of the ID, so use the exact name
that will unlock this volume.

The command prompts for the LUKS passphrase and prints only the 64-character
public ID to stdout. For automation with an existing passphrase file:

```sh
sudo nix run path:.#luks-volume-key-id -- \
  --device /dev/disk/by-uuid/YOUR-LUKS-UUID --name data \
  --key-file /run/luks-passphrase
```

The package includes Python and libcryptsetup. It reads the volume key in
memory without opening a mapping, modifying the device, or writing a key file.
The result is systemd's HMAC-SHA256 identity derived from the volume key,
LUKS UUID, and mapper name. It is neither the UUID nor the raw encryption key.
Obtain it on a trusted system after formatting; record it explicitly in the
configuration rather than learning a replacement from disk during boot.

Systems using [the secure-unlock module](secure-unlock.md) get a
`root-volume-key-id` command configured for their LUKS device and mapper name.

## Validation

```sh
nix build path:.#checks.x86_64-linux.luks-volume-key-id --no-link
```

The check uses disposable LUKS1 and LUKS2 images to verify the known ID,
mapper-name binding, the configured shortcut, rejection of invalid inputs, and
unchanged image contents.
