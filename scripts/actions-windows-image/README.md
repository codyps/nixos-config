# Windows 11 Actions runner images

`sys actions-windows-image` installs Windows 11 Pro from a user-supplied English
x64 ISO into a **new private qcow2 disk** on an x86_64 Linux KVM host. It installs
Git, PowerShell 7.6.10 (MSI), Visual Studio 2022 C++ Build Tools (including recommended
components), and an unregistered Windows x64 Actions runner. The image includes
UEFI with Microsoft Secure Boot keys and a software TPM 2.0. Guest device
encryption is disabled for the disposable image; Warbler encrypts the storage
volume on the host.

Enable `programs.actions-vm-image.enable` to install both image tools. From a
checkout, `nix run .#actions-windows-image -- --help` also works. The user needs
KVM access and write access to the build/publication parent directories.

On Warbler:

```sh
sys actions-windows-image \
  --iso "$HOME/Windows11_Client_x64_en-us_26300_9457.iso" \
  --work-dir /var/lib/actions-vm/build/windows11-v1 \
  --destination /var/lib/actions-vm/images/windows11-v1
```

Preparation requires 100 GiB free, creates a sparse 128 GiB disk, and defaults
to four CPUs and 8 GiB RAM. It rejects existing workspaces and published image
directories. The unattended answer file selects only virtual disk 0. No host
disk or filesystem is passed into the guest. The public Pro installation key
selects the edition and does not activate Windows or supply a Windows license.

The helper verifies GitHub's published SHA256 digests for downloaded runner,
Git, and PowerShell assets. Inside Windows, the Build Tools bootstrapper must
have a valid Microsoft Authenticode signature. Publication records downloaded
versions/hashes and the ISO SHA256. Verified downloads are cached by hash in
the build parent directory’s `downloads/`, so a fresh installation attempt can
reuse them after re-verification. Online Build Tools components can change;
this does not produce a byte-reproducible image.

A one-time local setup account logs in once, provisions the software, compiles
and runs a C smoke test, checks Git/PowerShell, and verifies the runner has no
registration or job workspace. Sealing removes automatic-logon credentials,
disables/randomizes the setup account, enables the runner startup task, and
shuts down cleanly. A private one-time HTTP callback carries only a success flag
and stage to the builder. Image preparation uses QEMU user networking for trusted
installation; production job networking uses the scaler's isolated bridge.

For diagnostics, VNC listens only on `127.0.0.1:5910` by default. Forward it with
`ssh -N -L 5910:127.0.0.1:5910 cody@warbler`. The workspace retains `qemu.log`,
`swtpm.log`, and a periodically refreshed `screen.ppm`. Installation has a
four-hour deadline and all child processes stop on failure/interruption. Failed
workspaces may contain a private installation ISO with temporary setup credentials;
keep them private. Diagnose a failed setup before starting a fresh workspace.

Publication requires the successful sealing receipt and QEMU shutdown. It checks
and compresses the disk and publishes read-only `windows.qcow2`, firmware, TPM
state, `vm.json`, and a hash manifest. Never edit a published image while a VM
references it. The host/scaler App key and GitHub runner registration are never
part of the image.

Production boots run `guest/windows-bootstrap.ps1` from the scaler sources as a
SYSTEM startup task. It waits for `RUNNER_SEED`, reads that job's JIT configuration
into the runner environment, invokes `run.cmd`, and shuts down when the runner
exits. Jobs have guest administrator privileges. The controller clones disk,
NVRAM, and TPM state for each VM and removes them after completion. This is a
build/CLI runner; interactive desktop tests have not been established.

Validate with `python3 scripts/test-actions-windows-image.py`, the scaler's Rust
and module tests, and a real job using `runs-on: warbler-windows`. A builder receipt
or host build alone does not prove job dispatch, network isolation, or cleanup.
