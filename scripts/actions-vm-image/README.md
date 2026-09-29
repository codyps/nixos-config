# macOS Actions runner images

This prepares the image contract consumed by
[actions-vm-scaler](../actions-vm-scaler/README.md). Run it on an x86_64 Linux KVM
host. It downloads pinned OSX-KVM boot assets and Apple recovery media at runtime;
macOS and SMC data are not included in the Nix package or this repository.

`build` automates the Sequoia/CLT image pipeline: Recovery boot, guarded disk
installation, first-boot SSH setup, toolchain/runner provisioning, sealing, and
publication. It recognizes a small set of Recovery and OpenCore screens, waits on
unknown screens, and fails at its installation deadline with saved diagnostics.
Console recognition currently targets English Recovery. Apple downloads and OS
installation can take tens of minutes; preparation counters exceeding 100% are
not a completion signal. The command waits for guest checks and clean shutdown.
The individual commands below remain available for console-assisted diagnosis.
A successful image build does not prove a real GitHub Actions job works.

## Automated Sequoia/CLT build

Create a fresh build key outside the repository and image workspace. On a Mac,
build the first-boot installer package using Apple's `pkgbuild`/`productbuild`:

```sh
mkdir -m 700 /private/tmp/macos-image-key
ssh-keygen -t ed25519 -N '' -f /private/tmp/macos-image-key/key
python3 scripts/actions-vm-image/image.py --work-dir /private/tmp/macos-image-key \
  bootstrap-package --public-key /private/tmp/macos-image-key/key.pub \
  --output /private/tmp/macos-image-key/bootstrap.pkg
```

Transfer `bootstrap.pkg`, its `bootstrap.json` key/hash manifest, and the private
key to a private directory on the KVM host. The package contains only the public
key, first-boot script, and launch daemon. It creates a hidden **non-admin** builder
account with no usable password or secure token, installs temporary key-based SSH
and a dedicated sudo rule, and marks Setup Assistant complete. No Apple account is
used. The private key is never put in the package, ISO, guest, or published image.

On Warbler, with the official osx-x64 runner archive and its published SHA256:

```sh
sys actions-vm-image --work-dir /var/lib/actions-vm-build/sequoia-auto build \
  --bootstrap-package /private/path/bootstrap.pkg \
  --identity /private/path/key \
  --runner-archive /private/path/actions-runner-osx-x64-VERSION.tar.gz \
  --runner-sha256 RUNNER_SHA256 \
  --destination /var/lib/actions-vm-images/sequoia-clt-v2
```

Create the parent directories with suitable ownership first. The initial profile
is Sequoia, 4 vCPUs, 8 GiB RAM and a private 128 GiB disk. The installation timeout
is three hours (`--timeout` in seconds); the VM remains owned by the foreground
command and is stopped on failure/interruption. SSH/VNC remain loopback-only.
Do not run untrusted jobs in this preparation VM.

The package and key are checked before disk installation. Existing publication
paths are refused. A workspace records its package hash and one-time erase marker;
rerunning with the same inputs resumes observation/provisioning without reissuing
the erase. Never delete that marker to fix a failed install. Inspect `screen.ppm`,
`screen-words.json`, `build-vm.log`, `qemu.log`, and `seal-failure.log` instead.
After success, delete the temporary private key. Keep published images immutable.
The builder shell and SSH access are revoked during sealing; bootstrap files,
keys and the sudo rule are removed. macOS may retain the unusable account record.

## Install the command

Import `nixos-modules/actions-vm-image.nix` and enable
`programs.actions-vm-image.enable`. This installs `sys actions-vm-image` without
enabling a scaler or modifying KVM module settings. The user running it needs
access to `/dev/kvm`. Alternatively, from the checkout on Linux:

```sh
nix run .#actions-vm-image -- --help
```

## Manual preparation and boot

Use a private, short, persistent path outside the source tree and Nix store:

```sh
sys actions-vm-image --work-dir /var/lib/actions-vm-build/sequoia prepare \
  --macos sequoia --disk-gib 128 --memory-mib 8192 --cpus 4
sys actions-vm-image --work-dir /var/lib/actions-vm-build/sequoia download
sys actions-vm-image --work-dir /var/lib/actions-vm-build/sequoia run --installer
```

Create the parent directory with suitable ownership first. `run` stays in the
foreground; keep its terminal/session open. Another process cannot prepare,
publish, or start a second VM against the same workspace. The OS disk and NVRAM
are private to this build; OpenCore uses a disposable overlay. Recovery uses a
QEMU temporary snapshot. There are no host filesystem shares or passthrough disks.
Guest S3/S4 sleep states are disabled because resume is unreliable with this
virtual hardware, including before provisioning can disable macOS idle sleep.
The preparation network is QEMU user networking with outbound connectivity; it is
**not** the scaler's production network isolation and must not run untrusted jobs.

Console and SSH forwards bind only to the KVM host's loopback. From another machine:

```sh
ssh -N -L 5909:127.0.0.1:5909 cody@warbler
```

Connect a VNC client to `127.0.0.1:5909`. Choose **macOS Base System** in OpenCore.
In Recovery, open Utilities > Terminal. From a second shell on the KVM host:

```sh
sys actions-vm-image --work-dir /var/lib/actions-vm-build/sequoia status
sys actions-vm-image --work-dir /var/lib/actions-vm-build/sequoia screenshot
sys actions-vm-image --work-dir /var/lib/actions-vm-build/sequoia install
```

`install` types a command into the **already focused Recovery Terminal**. Its
script requires exactly one whole disk of the configured capacity, checks for
`startosinstall` and existing installation volumes, and erases that private
virtual disk. The host records a one-time install-request marker before typing;
it will not blindly retry an erase. If that Recovery version lacks
`startosinstall`, use Disk Utility and the graphical installer instead. A failed
request needs console diagnosis, not deletion of the marker and an automatic retry.

Installer reboots are allowed. Select the installation entry as necessary, then
MACOS. `key right`, `key ret`, and `type 'text'` provide QMP console control with a
US keyboard. `screenshot` writes `screen.ppm`; `qemu.log` and `serial.log` remain in
the workspace on failure. `stop` forcibly exits QEMU and is for failed builds,
not clean shutdown or image sealing.

## Manual provisioning

Complete Setup Assistant with a **temporary local admin named `builder`**, no
Apple account, and no personal data. Enable Remote Login and install a temporary
SSH public key in `/Users/builder/.ssh/authorized_keys`. For unattended provisioning,
use a root-owned mode-0440 `/etc/sudoers.d/actions-vm-builder` containing:

```text
builder ALL=(ALL) NOPASSWD: ALL
```

Keep the private key outside the workspace and repository. The tool pins the
first SSH host key to the workspace's `known_hosts`; subsequent mismatches fail.
Use a fresh workspace for a replacement guest. Download the official `osx-x64`
Actions runner archive and obtain its published SHA256. Supply an Apple Xcode
`.xip` or Command Line Tools `.pkg` with a separately verified SHA256, or provision
against an already installed toolchain. For a CLT-only image, use `--install-clt`
instead of `--toolchain` and `--toolchain-sha256`; Software Update selects the
latest compatible non-beta CLT package offered by Apple:

```sh
sys actions-vm-image --work-dir /var/lib/actions-vm-build/sequoia provision \
  --identity /private/path/build-key \
  --runner-archive /private/path/actions-runner-osx-x64-VERSION.tar.gz \
  --runner-sha256 RUNNER_SHA256 \
  --install-clt
```

The tool installs the toolchain, accepts the Xcode license/runs first-launch setup
when supplying Xcode, creates the unprivileged `runner`, installs the existing
scaler bootstrap, and disables guest sleep and unattended macOS updates. It does
not register a GitHub runner. Provisioning currently transfers an archive through
SSH and needs temporary space for the toolchain archive plus extracted Xcode.

## Seal and publish

Confirm the image boots without keyboard input after removing recovery media
(`run` without `--installer`). OpenCore scans only APFS/HFS volumes, preventing
its own EFI partition from becoming a boot-looping default. No Apple account,
signing identity, registered runner or job workspace belongs in the image.

```sh
sys actions-vm-image --work-dir /var/lib/actions-vm-build/sequoia seal \
  --identity /private/path/build-key \
  --builder-password-file /private/path/build-password
sys actions-vm-image --work-dir /var/lib/actions-vm-build/sequoia publish \
  /var/lib/actions-vm-images/sequoia-clt-v1
```

For a console-created account, keep the temporary builder password in a mode-0600
file outside the workspace. Omit this option for the package-created account.
macOS requires the old password to revoke a secure-token account password. The
tool sends it over SSH stdin; it is not placed in argv, logs, or the image.

For full Xcode images, add `--require-xcode` to `seal`. Sealing compiles and executes
C and Swift smoke tests as `runner`, rejects registered/worked runner state,
installs the job-seed boot daemon, removes SSH keys and the temporary sudo rule,
and requests a clean shutdown. Package-created builders retain an unusable
non-admin account record with a disabled shell and no SSH access; bootstrap
scripts are deleted. A successful guest receipt and QEMU exit are required before
publication.

Console-created accounts may be macOS's last protected administrator/secure-token
user. For those, sealing randomizes and discards the password, disables/hides the
account and its shell, and removes shell history. OS-generated home folders remain
behind root-only permissions because macOS privacy controls protect them from SSH
cleanup. Never use a personal account for image preparation.

Booting the workspace again invalidates sealing; it will need preparation access
restored to reseal it.

Publication refuses an existing destination, checks and flattens both qcow2 disks,
and publishes matching firmware, `manifest.json` with hashes, and `vm.json` for
`services.actions-vm-scaler.settings.vm`. Published files are read-only. Keep all
parent directories traversable by the scaler. Never modify a published image
while any overlay references it. GitHub credentials are supplied only by the
scaler at job boot, not by the image builder.

## Tests and acceptance

```sh
python3 scripts/test-actions-vm-image.py
cargo test --manifest-path scripts/actions-vm-scaler/Cargo.toml --locked
nix build .#actions-vm-image --no-link
```

Before declaring an image usable, run an actual GitHub job through the scaler,
including checkout, `sw_vers`, `xcodebuild -version` (full Xcode), compiler tests,
and a representative project build. Verify a second job gets a fresh disk and
that shutdown removes both OS and OpenCore overlays. GUI/Metal tests require a
separate login/session/graphics configuration and are not established by these
CLI checks.
