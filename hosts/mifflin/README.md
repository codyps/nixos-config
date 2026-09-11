# Mifflin VMware integration

## Observed guest

Inspected on 2026-09-10: VMware on an Intel i9-9880H, 8 virtual CPUs
(presented as 8 sockets), about 12 GiB RAM, a 100 GiB virtual SATA disk,
and 8.4 GiB disk swap. The network uses the emulated e1000 driver.
`vmwgfx`, `vmw_balloon`, VMCI and vsock were loaded, and both the system
VMware service and the desktop VMware agent were running. The desktop was
Plasma Wayland. The running desktop agent was older than the newly installed
system tools; logging out and back in refreshes it.

Balloon statistics could not be read: `vmware-toolbox-cmd stat balloon`
reported that the VMware Guest API is not enabled on the host. A loaded
balloon driver confirms guest support, not that Fusion is reclaiming RAM.
Memory hot-add onlining was already enabled by the running kernel.

## Guest policy

- Keep the full open-vm-tools desktop integration and explicitly load the
  balloon and VMCI drivers. Restart the system agent after failures.
- Enable [clipway](https://github.com/krisztianfekete/clipway), pinned in
  `flake.lock` and built against this flake's nixpkgs, for Wayland text
  clipboard sharing. Its user service follows `plasma-workspace.target`, stops
  with the session, and requires `WAYLAND_DISPLAY`. Disable the stock XDG
  VMware user-agent autostart to avoid competing desktop agents. The NixOS
  VMware module's X11 session command remains available for X11 logins.
  KWin exposes `ext_data_control_manager_v1` on this machine (verified with
  `wayland-info`), which the packaged wl-clipboard supports. Upstream does
  not certify KWin; verify host-to-guest and guest-to-host text interactively.
  Clipway supports UTF-8 text only, not images, files, rich text or drag-and-drop.
- Automatically online hot-added CPUs and memory when the host offers them.
  This does not enable hot-add in Fusion or implement hot removal.
- Use NTP for periodic clock discipline, retaining VMware one-off corrections
  after suspend/resume and restore. The tools configuration disables only
  periodic synchronization, as recommended by
  [VMware's Linux timekeeping guidance](https://knowledge.broadcom.com/external/article/310053/timekeeping-best-practices-for-linux-gue.html).
- Default to one local Nix build with `cores = 0`, allowing that build to use
  available CPUs without multiplying all-core builds. This is a throughput /
  responsiveness tradeoff: serial builds cannot fill the guest. Build scripts
  must honor `NIX_BUILD_CORES`; these settings are not hard resource caps.
  See [Nix cores versus jobs](https://nix.dev/manual/nix/2.34/advanced-topics/cores-vs-jobs.html).
- Give the Nix daemon lower CPU and I/O weights and a lower nice priority.
  These prioritize competing work inside Linux; they do not tell macOS to
  prioritize host applications. Trusted Nix clients can override defaults.
- Retain disk swap for memory pressure and weekly TRIM for disks that support
  it. The current disk reports zero discard capability, so TRIM cannot reclaim
  host storage with this virtual hardware. Remove the ineffective continuous
  `discard` mount option.

## Host-side follow-up

The guest cannot see the Mac's current memory pressure, Fusion allocation
policy, VMX configuration, or physical free disk space. Fully adaptive host
resource management cannot be guaranteed from NixOS alone.

1. Check Fusion's CPU/RAM allocation against actual macOS pressure during a
   representative build. Avoid reserving/locking all guest memory or disabling
   ballooning. Adjust allocation in Fusion if the Mac swaps or becomes slow;
   guest nice values are not host scheduling priorities.
2. Consider VMXNET3 instead of e1000 if supported by this Fusion/virtual hardware
   version. Linux has the driver already. Make the change with console access
   because interface naming and NetworkManager profiles may change.
3. Review the virtual disk/controller and Fusion's reclaim/cleanup support.
   Confirm nonzero `DISC-MAX` with `lsblk -D` before expecting guest TRIM to
   reclaim space. Do not change the boot disk controller or partition layout
   merely to enable discard without a recovery plan.
4. Host hot-add settings are separate from guest onlining. Support depends on
   Fusion/version/hardware; do not assume ESXi hot-add controls exist in Fusion.
5. Host clipboard sharing must be enabled in Fusion. Clipway supplies the
   Wayland text backend; VMware's stock
   [Wayland limitations](https://knowledge.broadcom.com/external/article/320995)
   still apply to features clipway does not implement, such as drag-and-drop.
6. `hosts/u3/darwin.nix` advertises four concurrent jobs for mifflin. Review that
   host-side scheduling value if remote builds still overcommit the guest;
   the guest's local build default is not a global admission controller for
   all remote clients.

## Verification after activation

```sh
systemctl status vmware.service run-vmblock\\x2dfuse.mount
systemctl --user status clipway.service
journalctl --user -u clipway.service -b
vmware-toolbox-cmd config get timeSync
systemctl status systemd-timesyncd.service
lsmod | rg 'vmw_balloon|vmw_vmci|vmwgfx|vmxnet3'
cat /sys/devices/system/memory/auto_online_blocks
systemctl show nix-daemon.service -p Nice -p CPUWeight -p IOWeight
lsblk -D
systemctl status fstrim.timer
```

Validate window resizing, clipboard in both directions, and suspend/resume
from the Fusion console. Those interactions cannot be proved by a Nix build.
The kernel command-line change takes effect after a reboot.

On 2026-09-11, the clipway system build passed and the compiled clipboard
plugin was checked for its Wayland backend. The built `clipway.service` was
enabled and started with `systemctl --user enable --runtime`, and the old
`app-vmware\x2duser@autostart.service` was masked/stopped for the current
runtime. Exactly one patched desktop agent was running afterward. This
session-only activation does not switch the system; activate the NixOS
configuration to make the service and autostart suppression survive reboot.
Host/guest clipboard round-trip testing remains an interactive console check.
