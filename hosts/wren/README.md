# Wren

Intel Mac mini (Macmini8,1), six-core 3.2 GHz Core i7 and 32 GiB RAM.
Initial setup targets macOS 15.8.1 and the existing `cody` account at `/Users/cody`.

The flake uses the separate pinned Nixpkgs, nix-darwin, and Home Manager 26.05
inputs for Intel Darwin. It manages Lix and includes the shared Darwin and
Home Manager configuration. The common cache module permanently configures
`nix-community.cachix.org` and `codyps.cachix.org` with their signing keys;
Wren also enables permanent acceptance of flake configuration.
The build-user group is explicitly pinned to GID 350, matching the Lix macOS
installer despite the shared Darwin configuration's legacy state version.

Build without activation:

```sh
nix build .#darwinConfigurations.wren.system --no-link
```

For the initial activation with the existing multi-user Lix installation:

```sh
nix build .#darwinConfigurations.wren.system
sudo ./result/sw/bin/darwin-rebuild switch --flake .#wren
```

Subsequent rebuilds:

```sh
sudo darwin-rebuild switch --flake .#wren
```

Activation changes the computer name and local hostname to `wren` and installs
the shared user configuration. Review any Home Manager file-collision errors
and preserve existing files before retrying activation.

## Unattended operation

Wren disables idle sleep and sleep from the power button, restarts after power
failure, and enables Apple's SSH server. Display sleep remains independent.
Weekly Nix garbage collection runs Sunday at 03:15 and deletes generations
older than 30 days before collecting unreferenced store paths. Keep a GC root
for any older generation needed for long-term recovery. Build-time APFS store
optimisation remains disabled.

Run long-lived workloads through `launchd.daemons`, using a dedicated account,
`RunAtLoad`, an appropriate `KeepAlive` policy, absolute store executable paths,
and persistent logs with rotation. These services must work before GUI login.
Use service credentials that do not require a login Keychain, GUI prompt, or
interactive SSH agent. For automated Git commits, use a dedicated identity and
configure noninteractive signing or disable signing in that workload's Git
configuration; the shared personal Git configuration enables OpenPGP signing.

Workload services, data backups, and external downtime/disk-space alerts need
to be configured when the workload and backup/monitoring destinations are known.

Before leaving Wren unattended:

1. Activate the configuration and verify key-based SSH access from another
   machine, including any VPN used for administration.
2. Check `sudo fdesetup status`. If FileVault is enabled, arrange a startup
   unlock/recovery method or physical access: this Intel Mac cannot use Apple's
   Apple-silicon/macOS-26 SSH FileVault unlock feature. Do not disable encryption
   without considering the data stored on the machine.
3. Reboot without logging in locally; verify SSH, VPN access, and workload
   services recover. Confirm service credentials work after this cold start.
4. Stop a workload process and confirm launchd restarts it as intended.
5. Test a controlled power interruption when workloads can safely be stopped,
   and verify the machine restarts and becomes remotely accessible.

Inspect power settings with `pmset -g custom` and the GC job with
`sudo launchctl print system/org.nixos.nix-gc`. Builds do not verify these
activation and recovery behaviors.

## Remote Nix builds

The hidden `nix-ssh` account (UID 450) accepts the shared keys in
`modules/builder-ssh-keys.nix`, including the personal keys registered in
`nixos/ssh-auth.nix` and u3's root builder key. SSH forces
`nix-daemon --stdio`; interactive shells, forwarding, passwords, and user SSH
startup files are disabled for this account. Keys are in a root-owned file.
The account is a trusted Nix user: only enroll keys from trusted personal
machines, never Actions guest keys. SSH restrictions do not make trusted Nix
access appropriate for untrusted clients.

Wren builds `x86_64-darwin` derivations with sandboxing enabled, at most two
concurrent derivations and three advertised cores per build. Build tools must
honor `NIX_BUILD_CORES` for that core budget to apply. Jobs requesting
`__noChroot` are rejected by the strict sandbox setting. Actual remote builds
must be tested after activation, including any packages requiring Apple tools.

Enroll each client's **daemon** SSH public key in `builder-ssh-keys.nix` and keep
the private key on that client. A personal SSH-agent key does not automatically
give the client's root Nix daemon access. Clients whose keys are absent from the
repository still need enrollment; the current list is not a complete host-key
inventory.

Wren runs the system Tailscale daemon at boot, with automatic restart. After
activation, enroll it using `sudo tailscale up --hostname=wren` and verify it is
reachable as `wren.little-moth.ts.net`. Avoid running a separate Tailscale GUI
client alongside this daemon. Tailnet enrollment and access policy remain
external to this configuration; make sure the device's key-expiry policy is
appropriate for an unattended builder.

On each client, generate a dedicated key with the upstream `ssh-keygen` tool:

```sh
sudo install -d -m 0700 /etc/nix/keys
sudo ssh-keygen -t ed25519 -N '' -f /etc/nix/keys/wren_ed25519
sudo cat /etc/nix/keys/wren_ed25519.pub
```

Do not overwrite an existing key. Enroll the public key in
`modules/builder-ssh-keys.nix` and rebuild Wren before enabling that client.

After confirming Wren's SSH host-key fingerprint, enable the shared client
module imported by the common NixOS and Darwin configurations:

```nix
p.nix.buildMachines.wren = {
  enable = true;
  publicHostKey = "BASE64_ENCODED_VERIFIED_SSH_PUBLIC_KEY";
};
```

The module pins the verified host key with `publicHostKey`, uses the dedicated
key path, and advertises only `x86_64-darwin`. Hosts with custom configuration
that does not import the common modules can import `modules/wren-builder-client.nix`
directly. u3's forced `nix.buildMachines` list must also be updated when enrolling
u3 so it does not discard Wren's entry. Client use is opt-in until enrollment is
complete, preventing failed remote-build attempts with absent keys.

Test `nix store ping --store ssh-ng://nix-ssh@wren.little-moth.ts.net`
with the enrolled identity and a real Darwin build from another host. Two slots
apply at Wren's daemon; do not advertise KVM or NixOS-test support on this host.

## GitHub Actions

Use a GitHub App installed on the selected personal repositories. The existing
`scripts/actions-vm-scaler` supports discovery across all repositories granted to
one App installation, with separate repository scale sets and a shared capacity
limit. Its current QEMU/KVM lifecycle and Linux network isolation cannot run on
Wren unchanged: a macOS VM backend and cold-boot/lifecycle validation are needed.

The intended layout is one disposable macOS VM per Actions job, initially with
capacity one. Keep registration credentials outside guests; discard each guest
and its writable disks after the job. Do not expose the host Nix daemon socket,
host SSH keys, or personal home directories to Actions guests. A host process
sandbox is not yet a validated substitute for this isolation. No Actions runner
is enabled by this configuration.
