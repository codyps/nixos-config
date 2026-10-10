# Disposable macOS GitHub Actions runners on Linux

`actions-vm-scaler` is a Rust scale-set client and single-host QEMU/KVM lifecycle
manager. It serves GitHub Actions jobs, not Nix remote-build requests. It uses
GitHub App authentication, outbound scale-set long polling, and JIT runners;
no public webhook, SSH bootstrap server, or persistent registered runner is needed.

The controller implements the wire protocol from
[`actions/scaleset` at e6daac702355cdb5b880b4fbdcf6d85dcd9e48e5](https://github.com/actions/scaleset/tree/e6daac702355cdb5b880b4fbdcf6d85dcd9e48e5).
It does not execute a Go sidecar. By default it discovers **every repository
accessible to the configured GitHub App installation**, including personal-account
repositories, and maintains a separate scale set for each. All repositories use
the same workflow label and share one host-wide VM capacity limit. Discovery is
refreshed every 60 seconds (configurable with `discovery_interval_secs`).
Archived/disabled repositories are excluded because they cannot execute jobs.

New grants are picked up automatically. Removed grants stop that repository's
listener and local VMs; other repositories keep running. A failed or partially
paginated discovery scan retains the previous membership. Numeric repository IDs
keep state stable across renames. Each repository has its own listener, retry loop,
registration namespace and persistent state under `repositories/<id>/`.

The scope remains one App installation on github.com and one Linux host per
process. GHES, multiple installations, multi-host placement and rolling image builds are not implemented. The companion
[image builder](../actions-vm-image/README.md) automates image preparation,
installation, first-boot setup, provisioning, sealing, and publication. Keep GARM handling the
existing Linux scale sets. Supplying a nonempty `github_url` explicitly selects
legacy single-repository/organization mode; **omit it for all granted repositories**.

## Image contract

Prepare a working x86_64 macOS installation using your tested OSX-KVM/OpenCore
configuration. The controller never runs the installer. The runtime requires:

- A **qcow2** macOS base disk, cleanly shut down; no backing-file chains pointing
  into transient directories. Flatten it during image publication if needed.
- A **qcow2** OpenCore boot disk, with automatic boot selection configured.
- A matching raw OVMF code image and raw, initialized OVMF variable-store template.
- Tested QEMU machine, CPU, SMBIOS and SMC parameters for this image and host.
  Supply these as `hardware_args` option/value pairs, not a shell command.
- A local `runner` account with passwordless sudo inside the disposable VM with home `/Users/runner`, and a current
  **osx-x64** GitHub Actions runner extracted to `/Users/runner/actions-runner`.
  Do not run `config.sh` or register the golden image.
- Xcode or CLT, accepted licenses/first-launch setup, and required build tools
  already installed. Disable guest sleep and unattended OS upgrades. The CLI
  bootstrap does not establish a GUI login session; GUI/Metal tests need additional
  image support and are not validated by this implementation.

Install the guest files **inside the golden VM**, as root:

```sh
install -d -o root -g wheel -m 0755 /usr/local/libexec
install -o root -g wheel -m 0755 bootstrap.sh /usr/local/libexec/actions-vm-bootstrap
install -o root -g wheel -m 0755 runner.sh /usr/local/libexec/actions-vm-runner
install -o root -g wheel -m 0644 org.actions-vm.bootstrap.plist /Library/LaunchDaemons/
```

Shut down and publish the image without loading the launch daemon in the image
preparation session. The daemon runs on the next boot, reads the per-VM JIT config
from the `RUNNER_SEED` ISO, runs the runner as `runner`, and shuts down when it
exits. If seed media is missing it shuts down after its bounded wait. Keep these
scripts root-owned and not writable by the runner account.

The image must not contain a registered runner, App key, PAT, Apple account,
signing credentials or previous job workspace. Inject job secrets using Actions.
Give the scaler read-only access to image assets under a versioned directory such
as `/var/lib/actions-vm-images/sequoia-xcode-16-v1/`. Do not put them under the
scaler's writable state directory. Publish a new directory for each image version;
never mutate a base while any overlay still references it. The code itself does
not redistribute macOS, firmware, OpenCore or SMC data.

## NixOS service

The exported `nixosModules.actions-vm-scaler` module is opt-in. Warbler enables it
with capacity one and the published Sequoia/CLT image. Set `imageConfigFile` to a
published `vm.json` to load its hardware settings at service startup without
copying them into Nix source. Explicit `settings.vm` values and the module's
executable/TAP settings take precedence. Example in an x86_64 Linux host module:

```nix
{
  imports = [ ../../nixos-modules/actions-vm-scaler.nix ];
  services.actions-vm-scaler = {
    enable = true;
    capacity = 1;
    privateKeyFile = "/run/secrets/garm-app-key";
    settings = {
      # No github_url: automatically discover all repositories granted to this installation.
      discovery_interval_secs = 60;
      scale_set = "warbler-macos-intel";
      runner_group_id = 1;
      app_id = "5099875";
      installation_id = 165554289;
      startup_timeout_secs = 900;
      job_timeout_secs = 21600;
      vm = {
        base_disk = "/var/lib/actions-vm-images/v1/macos.qcow2";
        opencore_disk = "/var/lib/actions-vm-images/v1/OpenCore.qcow2";
        firmware_code = "/var/lib/actions-vm-images/v1/OVMF_CODE.fd";
        firmware_vars = "/var/lib/actions-vm-images/v1/OVMF_VARS.fd";
        memory_mib = 8192;
        cpus = 4;
        # Copy the tested hardware parameters from your golden VM. Example shape
        # only: these values do not establish compatibility with your image.
        hardware_args = [
          "-machine" "q35"
          "-cpu" "YOUR_TESTED_CPU_MODEL_AND_FEATURES"
          "-device" "isa-applesmc,osk=YOUR_EXISTING_SMC_CONFIGURATION"
          "-smbios" "type=2"
        ];
      };
    };
  };
}
```

An existing GitHub App installation can be reused with repository Administration
read/write permission and access granted to the desired repositories. Select
"All repositories" on that installation to include future personal repositories,
or grant selected repositories individually. The scaler reads the installation's
paginated repository list; no manually maintained repository list is needed.
Choose a new scale-set name, separate from GARM's names. The name is created
independently in each repository, so every workflow uses the same `runs-on` label.
Only one listener may own a particular repository's scale set at a time.

`capacity` is the **total number of VMs across all repositories**, not a per-repo
allowance. TAPs are leased from a shared FIFO pool and are released only after
QEMU stops and cleanup completes. Waiting listeners wake when slots become
available. Running jobs are not preempted for fairness. GitHub may assign queued
work in multiple repositories before those repositories get a physical VM slot.

For explicit single-organization mode, `github_url` selects the organization and
its App needs organization self-hosted-runner permissions. When changing an
existing single-scope installation to discovery mode, stop/drain the service and
archive its old state directory first; the ownership guard intentionally refuses
to reinterpret old state as a different scope.

The service supplies absolute executable paths, a private state directory,
systemd credentials, and isolated TAP slots. It creates `avmbr0` on
**10.78.0.0/24**, TAPs `avm0`…`avmN`, DHCP/DNS, NAT, and nftables rules. Ensure
these names and the subnet are unused before enabling. The module enables IPv4
forwarding and adds its own guest filtering chains. If the host already enables
NixOS forward filtering, it also adds the corresponding guest allow rules.
Guests can reach public IPv4 addresses and host DHCP/DNS, but cannot initiate
connections to private/tailnet/link-local destinations, host services, other
guests, or IPv6 networks. Each TAP has a fixed DHCP reservation and bridge rules
that reject spoofed source MAC, IPv4 and ARP addresses. Image files are not shared into guests. TAP devices are
pre-created for the service account; QEMU runs without root or CAP_NET_ADMIN.

The network units intentionally retain the bridge/TAPs until reboot. If removing
or shrinking this service, stop it before manually removing unused interfaces.
The current module reserves these fixed names for its one instance.

Select the runner in an Actions workflow:

```yaml
jobs:
  build:
    runs-on: warbler-macos-intel
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4
      - run: |
          uname -m
          sw_vers
          xcodebuild -version
          # Your build/test command here
```

The guest is a macOS runner, so Linux container actions and service containers
are not available. Install required macOS tooling in the image or workflow.

## Lifecycle and failure behavior

1. Authenticate the App, exchange a runner-registration token for the Actions
   service connection, find/create the named scale set, and acquire a session.
2. Advertise the number of TAP slots as maximum capacity, acquire available jobs,
   and use `totalAssignedJobs` to size the pool from zero up to that capacity.
3. Persist a unique runner-name intent **before** asking for JIT configuration.
   Create a qcow2 overlay, private NVRAM copy and seed ISO, then launch QEMU.
4. Track started/completed events. Acknowledge the queue message only after its
   effects succeed. Repeated messages do not duplicate existing VMs or reset
   deadlines; unknown/previously removed runner names never select local paths.
5. On completion, guest exit, startup/idle timeout or job timeout, kill/reap QEMU,
   remove any remaining registration, and delete its disk/seed/NVRAM state.
   Capacity stays reserved while remote cleanup is failing.

This initial version has zero warm runners. Excess idle guests after cancellation
expire at the startup/idle deadline rather than being killed based on possibly
stale statistics. Deadlines are checked between API operations; HTTP requests
are bounded but this is not a precise real-time deadline scheduler. Configure
the Actions workflow timeout below the controller's job deadline.

Transient API failures use capped exponential backoff and preserve running VMs.
Queue/admin token expiry is refreshed. A lost session restarts that repository's
listener and VMs; other repositories are unaffected. Graceful service stop stops
all VMs, so drain workflows before maintenance. QEMU uses a parent-death
signal on Linux and systemd cleans the service cgroup. Startup reconciles durable
intents by runner name, including registrations whose JIT response was lost.
It does not attempt to adopt an old running VM. If access is revoked and GitHub
registration cleanup is forbidden, local VMs/disks are still removed, retaining
only empty intent directories for a future regrant. Startup also removes stale
local disks for repositories no longer accessible after a controller crash.
Do not run multiple controllers against the same repository scale set or share
state directories across hosts.

The golden disk and OpenCore disk are never written by the manager. Guest writes
go to private OS and OpenCore overlays; NVRAM is copied per instance. Budget physical disk space
for **capacity × guest disk virtual size**, plus images and image publication.
Deleting a VM deletes its local QEMU log as well; use Actions artifact/log upload
for build diagnostics. QEMU logs are available in `runs/avm-*/qemu.log` while the
VM exists. No guest memory snapshots are used.

Admin commands follow repository conventions:

```sh
sudo sys actions-vm-scaler check /path/to/config.json
systemctl status actions-vm-scaler
journalctl -u actions-vm-scaler
```

`check` validates JSON and file existence without GitHub writes or starting VMs.
The running service config uses a systemd credential path, readable inside that
service. For standalone checking, supply a config pointing at an accessible
runtime key file. A standalone `run` additionally requires pre-created isolated
TAPs and Linux KVM. The service's persisted state is mode 0700; never expose its
JIT media or state in logs or an HTTP server.

Avoid parallel diagnostic session-creation probes against an active listener:
creating a session with the same listener identity invalidates its existing session.

## Validation

```sh
cargo test --manifest-path scripts/actions-vm-scaler/Cargo.toml --locked
cargo clippy --manifest-path scripts/actions-vm-scaler/Cargo.toml --all-targets --locked -- -D warnings
nix build path:.#packages.x86_64-linux.actions-vm-scaler --no-link
```

Tests exercise paginated installation discovery, grants/removals/renames,
shared FIFO capacity, HTTP authentication/protocol contracts, session refresh,
redelivery, disk isolation, registration recovery, child exit/deadlines and cleanup
using a local HTTP server and fake VM executables. The PEM under `tests/fixtures`
is a generated **test-only key with no GitHub identity**.

Before production use, validate the actual prepared image and CPU flags on the
Linux host, then run a real Actions job from zero, simultaneous jobs at capacity,
cancel during boot and during execution, restart the controller, interrupt API
access, and verify replacement guests have fresh disks. Probe host/LAN/tailnet
and guest-to-guest isolation from a guest. Unit tests and a Nix build do not prove
those host/guest integration properties.
