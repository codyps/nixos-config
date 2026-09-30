# macOS image-builder validation (2026-09-28)

The [image workflow](../../scripts/actions-vm-image/README.md) is implemented and
validated on Warbler's AMD Ryzen 3 PRO 5350GE with QEMU 11.1.1 and KVM enabled.
The first published image is `/var/lib/actions-vm-images/sequoia-clt-v1` on Warbler.

| Component | Validated version |
| --- | --- |
| macOS Sequoia | 15.8, build 24H23 |
| Command Line Tools | 16.4.0.0.1.1747106510 |
| Apple clang | 17.0.0 |
| Apple Swift | 6.1.2 |
| GitHub Actions runner | 2.337.0, osx-x64 |

No full Xcode, Apple account, GitHub registration credentials, signing identities,
or personal data were installed. The runner archive's GitHub-published SHA256
was verified before use; Apple Software Update installed CLT. The published
`manifest.json` records the runner hash, guest validation receipt, and image hashes.
`vm.json` supplies the scaler's VM image/hardware settings.

## Original console-assisted image checks

- Real Recovery boot, guarded selection of the private 128 GiB disk,
  `startosinstall`, installer reboots, Setup Assistant, and SSH provisioning.
  The guest uses 4 CPUs and 8192 MiB RAM. Host KVM module settings were unchanged.
- Cold boot without recovery media or keyboard input reaches macOS and SSH.
- The unprivileged `runner` executes Runner.Listener and compiles, links, and
  executes both C and Swift programs using CLT.
- Sealing revokes the temporary builder password, disables/hides that account
  and its shell, removes SSH authorized/host keys, shell history and its sudo rule,
  installs the job-seed boot daemon, and receives a successful receipt followed
  by a clean guest shutdown. macOS protects its last secure-token account and
  generated home folders: the disabled account record and root-only template home
  remain. The `runner` is not an administrator.
- Publication checks and flattens both qcow2 disks, writes hashes, and makes the
  published assets root-owned and read-only.
- A fresh published clone boots with a new UUID, private OS/OpenCore overlays,
  copied NVRAM, no USB input devices, and the scaler's headless QEMU/sandbox layout.
  With an empty job seed it requests `guest-shutdown` after 161.9 seconds and QEMU
  exits 0. All published disk/firmware hashes remain unchanged. The test uses
  restricted user networking, not the production TAP network or GitHub API.
- Sixteen image tests pass on Warbler, including real qcow2 flattening, hashes/modes,
  Recovery disk selection, private password transport, and failed-seal diagnostics.
- The scaler's 21 Rust tests and Clippy pass; its native Nix package builds on
  Warbler, including the Linux check phase. Python lint/format and shell syntax
  checks pass. Flake evaluation and the affected system build pass.
- Separate KVM fixtures confirm builder SIGTERM/SIGKILL stops its QEMU child and
  releases the workspace lock.

Live validation fixed writable IDE OpenCore overlays, the Recovery `WholeDisk`
plist key, unreliable S3/S4 resume, console key pacing, and OpenCore scanning its
own EFI partition as a boot target. APFS/HFS-only scanning permits automatic boot.
Sealing now handles secure-token account constraints and retains failure logs.

## State and remaining acceptance

During the image validation above, the Warbler configuration was not activated
and the scaler was not enabled. See the later activation below. The original image used console assistance for initial Recovery and
Setup Assistant. A real GitHub job and second-job isolation through the scaler
still require acceptance testing; guest compiler checks do not establish that.
The preparation network is QEMU user networking, not production TAP isolation.

The private build workspace is `/var/tmp/actions-vm-image-validation`; it contains
the sealed source disk, pinned boot assets, recovery media and build logs. Published
assets are separate. Do not boot or modify the published disks directly.
The temporary package checkout is `/var/tmp/actions-image-package`.

The final built command is available without activation:

```sh
/nix/store/62xpni3d3g1ih2039f9jlw52sq4i9k6s-nixos-system-warbler-26.11.20260926.e158d9e/sw/bin/sys actions-vm-image --help
```

The original validation VMs are stopped. Their temporary build passwords/private
keys and bootstrap HTTP server were removed. Clone evidence is retained at
`/var/tmp/actions-vm-clone-smoke/receipt.json` and `qemu.log`; the smoke script is
`/var/tmp/actions-vm-clone-smoke.py`. Its disposable disks were removed after the
hash check. The published image and sealed build workspace remain available.

## Automated setup validation

The new `bootstrap-package` and `build` commands target Sequoia with Command Line
Tools only. Apple's macOS packaging tools create a package containing the public
build key and a first-boot daemon. The Linux controller recognizes Recovery
screens, issues the guarded installer command once, waits for SSH, then provisions,
seals and publishes the image.

The first development run reached the installed OS and skipped Setup Assistant.
It exposed two first-boot issues, both fixed and tested in the guest: a package
installed into a running system must explicitly load its launch daemon, and the
non-admin builder needs membership in `com.apple.access_ssh`. A normal reboot
confirmed the daemon itself worked; installing the corrected package confirmed
immediate loading without a reboot. SSH works with the public-key-only builder.

A fresh run in `/var/tmp/actions-vm-auto-e2e` installed macOS 15.8.1 (24H32),
skipped Setup Assistant, and reached authenticated SSH without console
intervention. The builder is UID 501, is not an administrator, belongs to the SSH
access group, and has no secure token. This evidence is saved in
`bootstrap-validation.txt`. Apple may resolve the same Sequoia recovery media to
a newer patch release, so the seal receipt records the actual installed version.
The first seal attempt passed C/Swift compilation but macOS rejected deleting
the builder record (`eDSPermissionError`). The final seal instead verifies its
unusable password and non-admin status, sets its shell to `/usr/bin/false`, removes
SSH access-group membership, and removes keys, bootstrap files and the sudo rule.
The remaining home is root-owned and mode 0700. The successful receipt confirms
both compiler checks, access revocation and macOS 15.8.1, followed by clean shutdown.

Validation used a fresh unattended install through SSH/CLT provisioning, followed
by a resumed build after repairing temporary access for the seal fix. Resuming
also exposed Recovery-media boot priority: the controller now omits Recovery once
an installed OS has been verified. That path passed live and has regression
coverage. A second complete blank-disk run of the final revision was not repeated.
The resumed `build` command exited successfully and published the image. The final
root-owned publication is `/var/lib/actions-vm-images/sequoia-clt-auto-v1`; all
assets are mode 0444. The sealed build workspace remains
`/var/tmp/actions-vm-auto-e2e`. Its `manifest.json` equivalent is `image.json`,
which contains the successful validation receipt; the rejected deletion attempt
is preserved separately in `seal-account-deletion-failure.log`.

All 16 image tests pass on Warbler, including qcow2 publication and resume-media
selection. Python lint/format and shell syntax checks pass, and the final Warbler
system build above includes these changes. That build did not activate the host;
see the later activation below. Temporary private build keys and the diagnostic HTTP server have been removed.

A fresh headless clone of the automated image booted with a new UUID, private
OS/OpenCore overlays, copied NVRAM, no USB input devices and an empty job seed.
It requested `guest-shutdown` after 165.7 seconds; QEMU exited 0 and all published
disk/firmware hashes remained unchanged. Evidence is retained in
`/var/tmp/actions-vm-auto-clone-smoke/receipt.json` and `qemu.log`; the harness is
`/var/tmp/actions-vm-auto-clone-smoke.py`. Its disposable disks and the intermediate
publication under `/var/tmp/actions-vm-images` were removed. The validation VM is
stopped. This is still an empty-seed boot test, not a real GitHub job or production
TAP-network isolation test.


## Autoscaler activation (2026-09-28)

Activated with `nix run .#nixos-rebuild-remote -- warbler switch`. The running
system is `/nix/store/9ayvpp6w5pbyp94ljayp9cibzvd89d5w-nixos-system-warbler-26.11.20260926.e158d9e`.
The scaler uses `sequoia-clt-auto-v1`, one shared VM slot, 4 CPUs and 8192 MiB RAM.
Its label is `warbler-macos-intel`. It reuses the existing SOPS-managed GitHub App
credential and discovers the currently granted `codyps/zpl` and
`codyps/zpl-comparison` repositories. GARM continues serving Linux runners.

The scaler and DHCP services are active with zero restarts; input-file validation
passed and both repository workers started without listener errors. The runtime
configuration is mode 0600 and points to the published image. The service account
can read the image and access KVM. The `avmbr0`/`avm0` network, DHCP, NAT, private
address filtering and bridge anti-spoof rules are present on the running host.
All 21 scaler tests and 16 image tests passed in their respective validation
runs, and the activated system built successfully. A real GitHub job and active
guest network-isolation probes remain separate acceptance work.


## Session refresh repair and first Actions job (2026-09-29)

The scaler accepted initial sessions but rejected token-refresh responses because
GitHub returns `statistics: null` on refresh. The decoder now models session
statistics as optional, matching the upstream protocol. Initial missing statistics
start with zero demand until queue messages supply counts. The queue-refresh test
uses the observed null response and verifies polling, acquisition, and acknowledgment
with the replacement token. All 21 native scaler tests passed in the Nix build;
Rust formatting and diff checks also passed.

Warbler was switched to
`/nix/store/2wbhp39gfj95rzlsqnzi934kq1s959yl-nixos-system-warbler-26.11.20260926.e158d9e`.
The new scaler started both repository listeners and a disposable VM, which
registered and executed the macOS job in
[zpl CI run 36523272814](https://github.com/codyps/zpl/actions/runs/36523272814).
This verifies actual job pickup, execution, and runner cleanup. The Nix installation
step failed because the image's unprivileged runner lacks passwordless sudo;
it does not establish a successful macOS shell build or Cachix upload.

Diagnostic session creation under the existing listener identity invalidated its
previous session and caused HTTP 400 refresh errors in the old process. The
configuration switch replaced that process and cleared the stale session state.
Avoid parallel session-creation probes against an active listener.


## Disposable runner sudo access (2026-09-29)

The operator selected passwordless guest sudo, matching the Linux CI setup.
Provisioning now installs a root:wheel, mode-0440 sudoers rule for `runner`, and
sealing verifies `sudo -n` as that account. The runner remains outside the macOS
admin group; the sudoers rule grants root inside its disposable VM.

A separate copy of the sealed workspace was repaired through Recovery; the old
published image was not modified. A one-time normal-boot verifier checked the
sudoers syntax and ownership, confirmed `sudo -n id -u` returned zero as `runner`,
ran Clang and Runner.Listener, checked absence of registered runner state, restored
the job bootstrap daemon, removed itself, and shut down cleanly. Its receipt is
`/var/tmp/actions-vm-sudo-v2/sudo-validation.txt` on Warbler. The replacement image
is published at `/var/lib/actions-vm-images/sequoia-clt-sudo-v2`, with provenance
and receipt in its manifest. This version was subsequently superseded by the
Full Disk Access image below.


## Headless Full Disk Access (2026-09-29)

The sudo-enabled image reached Nix volume creation but macOS denied the installer's
`vifs` access to `/etc/fstab`. The operator approved guest Full Disk Access for the
shell and Actions runner process chain, including persistence for future images.
`guest/runner-access.sh` is now included in image-build media for use against the
offline Data volume in Recovery. SIP and Warbler host permissions are unchanged.

The unpublished working copy received the five scoped TCC entries from that
helper. A normal headless boot verified `sudo -n env EDITOR=/usr/bin/true vifs`
as `runner`, then removed the empty test fstab. The same boot rechecked sudoers
ownership/mode, passwordless sudo, Clang, Runner.Listener, and absence of prior
job registration. Its temporary verifier removed itself, restored the job
bootstrap daemon, and shut down cleanly. The receipt contains
`HEADLESS_VIFS_VALIDATED` and `RUNNER_SUDO_VALIDATED` and is retained in the
`sequoia-clt-fda-v3` image manifest. The configuration selects this new version;
previous published images remain unchanged. All 16 image-helper tests passed
on Warbler using Python 3.14 and QEMU; shell syntax and diff checks passed.

Warbler was then successfully built and switched to
`/nix/store/maga9dwkndz9fayf829d096gvlkmk7jr-nixos-system-warbler-26.11.20260926.e158d9e`.
All 21 scaler tests passed during that build. The real macOS Actions job passed
Nix installation and Cachix configuration with the new image.

The first shell build completed its package derivations, including release-plz,
but `nix develop` fell back to host Bash 3.2 after attempting to select
`bashInteractive` from the unsupported unstable Intel-Darwin input. Bash rejected
the generated environment before upload. The zpl cache workflow now uses
`nix print-dev-env --profile` to realize the same environment without launching
a shell (commit `45b820c0a9979affded20ad11a9ac56159a069b1`).

The corrected [zpl CI run 36576819797](https://github.com/codyps/zpl/actions/runs/36576819797)
passed all jobs, including Linux and Intel macOS shell caching. The macOS upload
reported 110 paths already present and successfully pushed release-plz 0.3.165
plus `/nix/store/p44g0p2jvqzywh14vw7j70ypccdxwci3-nix-shell-env` to `codyps`.
The scaler removed the completed runner at 10:14:24 EDT. One earlier VM in this
run exited before job pickup; the scaler replaced it automatically. This validates
successful real job execution and cleanup, but does not explain that startup exit.
