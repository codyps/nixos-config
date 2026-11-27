{ config, lib, pkgs, hardwareIdentities, ... }:
let
  sata = "/var/lib/warbler-sata";
  sataContainers = "${sata}/containers";
  sataData = "${sataContainers}/warbler-ai";
  usbip = config.boot.kernelPackages.usbip;
  vhci = "/sys/devices/platform/vhci_hcd.0";
  vhciControls = [ "${vhci}/attach" "${vhci}/detach" ];
  usbNodes = "/dev/warbler-ai-usb";
  aiGroup = toString config.containers.warbler-ai.config.users.groups.cody-ai.gid;
  mirrorUsbNode = pkgs.writeShellScript "warbler-ai-usb-device" ''
    set -eu
    case "$BUSNUM/$DEVNUM" in
      [0-9][0-9][0-9]/[0-9][0-9][0-9])
        node="${usbNodes}/$BUSNUM/$DEVNUM" ;;
      *) exit 0 ;;
    esac
    ${pkgs.coreutils}/bin/rm -f -- "$node"
    if [ "$ACTION" = remove ]; then exit 0; fi
    ${pkgs.coreutils}/bin/install -d -m 0755 -- "''${node%/*}"
    ${pkgs.coreutils}/bin/mknod -m 0660 -- "$node" c "$MAJOR" "$MINOR"
    ${pkgs.coreutils}/bin/chown root:${aiGroup} -- "$node"
  '';
in
{
  # These controls are host-wide, not namespaced. Allow per-process profiling
  # (including kernel time) and debugger attachment to same-UID dumpable tasks.
  # System-wide perf and tracing other users still require privileges.
  boot.kernel.sysctl = {
    "kernel.perf_event_paranoid" = 1;
    "kernel.yama.ptrace_scope" = 0;
  };

  # The container shares Warbler's kernel but cannot load modules itself. Load
  # both USB/IP halves: vhci-hcd for attaching remote devices and usbip-host
  # for exporting locally attached ones.
  boot.kernelModules = [ "usbip-core" "vhci-hcd" "usbip-host" ];
  environment.systemPackages = [ usbip ];
  systemd.tmpfiles.rules = [ "d ${usbNodes} 0755 root root -" ];
  services.udev.extraRules = ''
    # Expose usbfs nodes for imports through vhci, never physical controller devices.
    ACTION=="add|remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", DEVPATH=="/devices/platform/vhci_hcd.*/usb*/*", RUN+="${mirrorUsbNode}"
  '';

  # Primary AI environment: keep its persistent home separate from the legacy host home.
  # /var/lib is already persisted on Warbler's encrypted /persist filesystem.
  services.hardwareIdentities.templates."containers/warbler-ai/90-hardware.conf".text = ''
    [Link]
    MACAddress=${hardwareIdentities "warbler" [ "network" "containers" "warbler-ai" "interfaces" "mv-eno1" "macAddress" ]}
  '';
  # Do not name the container "ai": systemd-machined exposes every registered
  # machine name as an authoritative DNS domain, so a machine named "ai" makes
  # lookups such as z.ai and api.z.ai return NXDOMAIN. Keep the machine name
  # distinct from every real TLD.
  containers.warbler-ai = {
    allowedDevices = [{ node = "char-usb_device"; modifier = "rw"; }];
    bindMounts = {
      "/run/hardware-identities" = {
        hostPath = "${config.services.hardwareIdentities.stateDirectory}/current/containers/warbler-ai";
        isReadOnly = true;
      };
      "/dev/bus/usb" = {
        hostPath = usbNodes;
        isReadOnly = true;
      };
      # Replace nspawn's small tmpfs with private, disk-backed scratch space.
      "/tmp" = {
        hostPath = "/var/lib/warbler-ai/tmp";
        isReadOnly = false;
      };
      "/mnt/sata" = {
        hostPath = sataData;
        isReadOnly = false;
      };
    };
    autoStart = true;
    restartIfChanged = false;
    ephemeral = false;
    # nspawn otherwise filters perf_event_open; explicitly permit debugging
    # syscalls too, without granting cody-ai capabilities or sudo access.
    extraFlags = [
      "--system-call-filter=perf_event_open"
      "--system-call-filter=ptrace"
      "--system-call-filter=process_vm_readv"
      "--system-call-filter=process_vm_writev"
    ];
    privateNetwork = true;
    macvlans = [ "eno1" ];
    # A private link avoids macvlan's host/guest isolation without
    # changing the guest's LAN default route or depending on its DHCP lease.
    extraVeths.ai-ssh = { };
    config = {
      imports = [ ../../nixos-modules/ai-container ];
      networking.hostName = "warbler-ai";
      # The host loads the USB/IP modules; the guest needs the matching tools.
      environment.systemPackages = [ usbip ];
      systemd.tmpfiles.rules = [
        "d /mnt/sata/work 0700 cody-ai cody-ai -"
        "d /run/vhci_hcd 0700 cody-ai cody-ai -"
      ];
      systemd.network = {
        enable = true;
        networks."10-lan" = {
          matchConfig.Name = "mv-eno1";
          networkConfig = { DHCP = "yes"; IPv6AcceptRA = true; };
          dhcpV4Config = { ClientIdentifier = "mac"; SendHostname = true; };
        };
      };
      environment.etc."systemd/network/10-lan.network.d/90-hardware.conf".source = "/run/hardware-identities/90-hardware.conf";
      nixpkgs.pkgs = pkgs;
      networking.interfaces.ai-ssh.ipv4.addresses = [{ address = "10.79.0.2"; prefixLength = 24; }];
      # Allow all ports on the private link used by Tailscale's subnet route.
      networking.firewall.trustedInterfaces = [ "ai-ssh" ];
    };
  };
  systemd.services."container@warbler-ai" = {
    # Activate guest changes in place; container boundary changes need a restart.
    reloadIfChanged = true;
    after = [ "systemd-modules-load.service" "systemd-tmpfiles-setup.service" "systemd-udevd.service" ];
    unitConfig.RequiresMountsFor = [ "/var/lib/nixos-containers" sata ];
    # Stop the old "ai" instance before the renamed unit starts so its state is
    # no longer in use when preStart moves it.
    conflicts = [ "container@ai.service" ];
    postStart = ''
      # nspawn mounts the guest's sysfs after processing its static bind mounts.
      for control in ${lib.escapeShellArgs vhciControls}; do
        ${pkgs.systemd}/bin/machinectl bind warbler-ai "$control"
      done
    '';
    preStart = ''
      ${pkgs.coreutils}/bin/install -d -m 0755 ${usbNodes}
      # Delegate only the two writable vhci controls. The rest of sysfs stays read-only.
      ${pkgs.coreutils}/bin/chown root:${aiGroup} ${lib.escapeShellArgs vhciControls}
      ${pkgs.coreutils}/bin/chmod 0660 ${lib.escapeShellArgs vhciControls}
      # Replay existing VHCI devices if the udev rule was added during activation.
      ${pkgs.systemd}/bin/udevadm trigger --subsystem-match=usb --parent-match=${vhci} --action=add --settle

      # Only create the bind source once the SATA filesystem is mounted.
      if ! ${pkgs.util-linux}/bin/mountpoint -q "${sata}"; then
        echo "Warbler SATA storage is unavailable at ${sata}" >&2
        exit 1
      fi
      # The legacy host account shares the guest UID, so restrict the host parent.
      ${pkgs.coreutils}/bin/install -d -m 0700 "${sataContainers}"
      ${pkgs.coreutils}/bin/install -d -m 0755 "${sataData}"

      # Preserve the old container state while renaming it away from the "ai"
      # machine name. Refuse to start a second copy if the old unit is live.
      if [ -d /var/lib/nixos-containers/ai ] && [ ! -e /var/lib/nixos-containers/warbler-ai ]; then
        if ${pkgs.systemd}/bin/systemctl is-active --quiet container@ai.service; then
          echo "container@ai.service is still running; stop it before migrating state" >&2
          exit 1
        fi
        ${pkgs.coreutils}/bin/mv /var/lib/nixos-containers/ai /var/lib/nixos-containers/warbler-ai
      fi
      # Keep the legacy host AI account out of the container's scratch files.
      ${pkgs.coreutils}/bin/install -d -m 0700 /var/lib/warbler-ai
      ${pkgs.coreutils}/bin/install -d -m 1777 /var/lib/warbler-ai/tmp
      # Inherited by new files: no data COW, checksums, or compression. Scope
      # this to disposable scratch; Btrfs mount tuning would affect the host.
      if [ "$(${pkgs.util-linux}/bin/findmnt -n -o FSTYPE -T /var/lib/warbler-ai/tmp)" = btrfs ]; then
        ${pkgs.e2fsprogs}/bin/chattr +C /var/lib/warbler-ai/tmp
      fi
    '';
  };
  networking.interfaces.ai-ssh.ipv4.addresses = [{ address = "10.79.0.1"; prefixLength = 24; }];
  # Advertise only the container, not the host or the rest of the private /24.
  services.tailscale.extraSetFlags = [ "--advertise-routes=10.79.0.2/32" ];

  networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [ 2223 ];
  systemd.sockets.ai-container-ssh = {
    description = "AI container SSH over Warbler Tailscale";
    # BindToDevice stops the socket when Tailscale removes its interface.
    # Start it again whenever the replacement device appears, including boot.
    wantedBy = [ "sys-subsystem-net-devices-${config.services.tailscale.interfaceName}.device" ];
    socketConfig = {
      ListenStream = "2223";
      BindToDevice = config.services.tailscale.interfaceName;
      BindIPv6Only = "both";
    };
  };
  systemd.services.ai-container-ssh = {
    description = "Proxy Tailscale SSH connections to the AI container";
    requires = [ "container@warbler-ai.service" ];
    # Drop the inherited listener before its bound interface/socket disappears.
    # Otherwise the old proxy prevents the replacement socket from starting.
    bindsTo = [ "ai-container-ssh.socket" ];
    after = [ "container@warbler-ai.service" "ai-container-ssh.socket" ];
    serviceConfig = {
      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 10.79.0.2:22";
      DynamicUser = true;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
    };
  };
}
