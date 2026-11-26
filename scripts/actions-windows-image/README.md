# Windows 11 Actions runner images

`sys actions-windows-image` installs Windows 11 Pro from a user-supplied English
x64 ISO into a **new private qcow2 disk** on an x86_64 Linux KVM host. The v2
baseline includes Git/Git LFS, PowerShell 7, WinGet, Chocolatey, GitHub CLI,
7-Zip, jq, ripgrep, VS 2022 C++ Build Tools and Windows SDK, CMake, Ninja,
LLVM/Clang, WinLibs MinGW, Node/npm, Python/pip/uv, Rust/rustfmt/clippy, and the .NET LTS SDK.
The Actions runner remains unregistered until a job boots its disposable clone.

[packages.json](packages.json) pins bootstrap releases, WinGet package versions,
and both MSVC and GNU Rust toolchains. WinLibs/GNU Rust support existing GNU
Windows workflows. It selects explicit VS components instead of the moving
set of recommended components. Java, Go, MSYS2, WiX, browsers, Docker, WSL, and
vcpkg are not part of the baseline; add them when workflows justify them.
Workflows should still select their required language versions explicitly.

The image includes UEFI with Microsoft Secure Boot keys and a software TPM 2.0.
Guest device encryption is disabled for this disposable image; Warbler encrypts
the storage volume on the host.

## Build

Enable `programs.actions-vm-image.enable` to install both image tools. From a
checkout, `nix run .#actions-windows-image -- --help` also works. The user needs
KVM access and write access to the build/publication parent directories. On Warbler:

Run long builds in tmux or a persistent user service so an SSH/API command
timeout does not interrupt setup.

Windows setup can apply OOBE updates before the provisioning script starts.

```sh
sys actions-windows-image \
  --iso /var/lib/actions-vm/media/Windows11_Client_x64_en-us_26300_9457.iso \
  --work-dir /var/lib/actions-vm/build/windows11-v2 \
  --destination /var/lib/actions-vm/images/windows11-v2
```

Preparation requires 100 GiB free, creates a sparse 128 GiB disk, and defaults
to four CPUs and 8 GiB RAM. It rejects existing workspaces and published image
directories. The unattended answer file selects only virtual disk 0. No host
disk or filesystem is passed into the guest. The public Pro installation key
selects the edition and does not activate Windows or supply a Windows license.

The helper verifies GitHub's published SHA256 digests for downloaded runner,
Git, PowerShell, and WinGet bootstrap assets. These downloads are cached by hash
in the build parent directory's `downloads/` and reverified before reuse.
WinGet verifies package installer hashes against its source manifests; those
installers are downloaded inside the guest rather than the host cache. Build
Tools requires a valid Microsoft Authenticode signature. Publication records
bootstrap versions/hashes, the source ISO SHA256, and a snapshot of packages.json.
Online Build Tools components and WinGet dependencies can change, so this is
not a byte-reproducible image.

## Runtime account and sealing

V2 uses a local administrator named `runner`, with a real persistent profile.
[WinGet does not support SYSTEM](https://learn.microsoft.com/en-us/windows/package-manager/winget/troubleshooting),
which v1 used. Provisioning registers WinGet and installs user-scoped Rust tools
under the same account that will execute jobs.

The account logs in once for initial setup. Before reboot, provisioning removes
automatic logon, randomizes its password, and registers password-backed startup
tasks at highest privilege. Task Scheduler stores the random password; no
password file or interactive runtime logon is required. The account remains
enabled and its profile is retained. Published disks contain this local task
credential and must stay on trusted storage.

A deliberate reboot applies installer changes. A noninteractive finalization
task then tests WinGet registration/PATH/search, CLI commands, Git Bash, C/C++
with CMake/Ninja/MSVC, Clang, Rust builds/clippy, Python virtual environments,
uv, Node/npm, .NET, and archive creation. It writes a software inventory to
`C:\ProgramData\ActionsVm\software-inventory.json`, verifies no runner registration
or job workspace exists, removes temporary preparation files and credentials,
enables the runtime task, and shuts down cleanly. Failure never publishes an
image. A private one-time HTTP callback carries only a success flag and stage.

Production boots run `guest/windows-bootstrap.ps1` from the scaler sources as a
startup task under `runner` (v1 remains compatible with SYSTEM). It waits for
`RUNNER_SEED`, reads that job's JIT configuration into the runner environment,
invokes `run.cmd`, and shuts down when the runner exits. Jobs retain guest
administrator privileges. No controller App key enters the image. The controller
clones disk, NVRAM, and TPM state per job and removes them after completion.
This is a build/CLI runner; interactive desktop tests have not been established.

## Diagnostics and validation

VNC listens only on `127.0.0.1:5910` by default; `--vnc-display 11` selects 5911
for a concurrent development build. Forward it with
`ssh -N -L 5910:127.0.0.1:5910 cody@warbler`. The workspace retains `qemu.log`,
`swtpm.log`, and a periodically refreshed `screen.ppm`. Installation has a
four-hour deadline and all child processes stop on failure/interruption. Failed
workspaces may contain a private installation ISO with temporary setup credentials;
keep them private. Diagnose a failed setup before starting a fresh workspace.
Guest errors are in `C:\Windows\Temp\actions-image-error.log` and the private
provisioning transcript; successful sealing removes the transcript.

Publication requires the successful sealing receipt and QEMU shutdown. It checks
and compresses the disk and publishes read-only `windows.qcow2`, firmware, TPM
state, `vm.json`, packages.json, and a hash manifest. Never edit a published image
while a VM references it.

Run `python3 scripts/test-actions-windows-image.py` and PowerShell parser checks
before building. A successful image build proves post-reboot guest smoke tests,
not GitHub dispatch, network isolation, or disposable-VM cleanup.

For rollout, retain v1 and configure an isolated temporary scaler instance with
the candidate vm.json, its own networkOctet/macSlotOffset, and scale-set name
`warbler-windows-canary`. Dispatch `.github/workflows/windows-builder-canary.yml`
on that scale set. The workflow exercises checkout/LFS, both shells, a forced
pinned WinGet reinstall, all smoke builds, and inventory artifact upload. Check
controller logs for successful dispatch, shutdown, isolation, and cleanup before
changing `hosts/warbler/actions-vm-scaler.nix` to the v2 image. Keep v1 available
for rollback. Building a candidate does not switch production.

Rebuild regularly with refreshed package pins and a patched Windows ISO. Windows
automatic updates are disabled to avoid job-time restarts; this tool does not
apply cumulative updates automatically. Treat applying Windows servicing updates
as an explicit image-maintenance step and validate the resulting image again.
