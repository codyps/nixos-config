{ config, lib, pkgs, hardwareIdentities, ... }:
let
  # Host udev mirrors USB nodes into a directory shared with the guest.
  usbDeviceNode = pkgs.writeShellScript "crow-ai-usb-device" ''
    set -eu
    case "$DEVNAME" in
      /dev/*) node="/dev/crow-ai-usb/''${DEVNAME#/dev/}" ;;
      *) exit 0 ;;
    esac
    if [ "$ACTION" = remove ]; then
      ${pkgs.coreutils}/bin/rm -f -- "$node"
      exit 0
    fi
    ${pkgs.coreutils}/bin/mkdir -p -- "$(${pkgs.coreutils}/bin/dirname "$node")"
    kind=c
    if [ "$SUBSYSTEM" = block ]; then kind=b; fi
    ${pkgs.coreutils}/bin/rm -f -- "$node"
    ${pkgs.coreutils}/bin/mknod -m 0600 -- "$node" "$kind" "$MAJOR" "$MINOR"
    # Translate the AI user's IDs into the host namespace.
    ${pkgs.coreutils}/bin/chown ${toString (config.containers.crow-ai.privateUsers + 1001)}:${toString (config.containers.crow-ai.privateUsers + 993)} -- "$node"
  '';
in
{
  imports = [ ./ai-container-runtime.nix ./usb-mounts.nix ];
  # These controls are host-wide, not namespaced. Allow per-process profiling
  # (including kernel time) and debugger attachment to same-UID dumpable tasks.
  # System-wide perf and tracing other users still require privileges.
  boot.kernel.sysctl = {
    "kernel.perf_event_paranoid" = 1;
    "kernel.yama.ptrace_scope" = 0;
  };
  # The guest cannot load the host kernel modules needed by nested Docker or FUSE.
  # Register USB disk majors before systemd resolves the device allowlist.
  boot.kernelModules = [ "overlay" "bridge" "veth" "br_netfilter" "xt_nat" "ip_tables" "iptable_nat" "fuse" "usb_storage" "uas" "sd_mod" ];

  # Primary AI environment; no AI account or sandbox is created on the host.
  # /var/lib is persisted on Crow's encrypted /persist filesystem.
  services.hardwareIdentities.templates."containers/warbler-ai/90-hardware.conf".text = ''
    [Link]
    MACAddress=${hardwareIdentities "warbler" [ "network" "containers" "warbler-ai" "interfaces" "mv-eno1" "macAddress" ]}
  '';
  # Do not name the container "ai": systemd-machined exposes every registered
  # machine name as an authoritative DNS domain, so a machine named "ai" makes
  # lookups such as z.ai and api.z.ai return NXDOMAIN. Keep the machine name
  # distinct from every real TLD.
  # Keep the directory stable so the running guest sees hotplug updates.
  systemd.tmpfiles.rules = [
    "d /dev/crow-ai-usb 0755 root root -"
    "d /dev/crow-ai-usb/bus/usb 0755 root root -"
  ];
  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEMS=="usb", ENV{MAJOR}!="", ENV{CROW_AI_USB}="1", RUN+="${usbDeviceNode}"
    ACTION=="remove", ENV{CROW_AI_USB}=="1", RUN+="${usbDeviceNode}"
  '';
  containers.crow-ai = {
    bindMounts."/run/hardware-identities" = {
      hostPath = "${config.services.hardwareIdentities.stateDirectory}/current/containers/warbler-ai";
      isReadOnly = true;
    };
    autoStart = true;
    restartIfChanged = false;
    ephemeral = false;
    # RootlessKit uses a TUN interface inside its user/network namespace.
    enableTun = true;
    # USB spans many device majors; only USB nodes are mirrored into the guest.
    allowedDevices = [
      { node = "/dev/fuse"; modifier = "rw"; }
      { node = "char-*"; modifier = "rw"; }
      { node = "block-*"; modifier = "rw"; }
    ];
    bindMounts."/run/crow-ai-usb-devices" = {
      hostPath = "/dev/crow-ai-usb";
      isReadOnly = true;
    };
    bindMounts."/dev/bus/usb" = {
      hostPath = "/dev/crow-ai-usb/bus/usb";
      isReadOnly = true;
    };
    bindMounts."/dev/fuse" = {
      hostPath = "/dev/fuse";
      isReadOnly = false;
    };
    # nspawn otherwise filters perf_event_open; explicitly permit debugging
    # syscalls too.
    extraFlags = [
      "--network-ipvlan=wlp6s0"
      "--network-ipvlan=enp3s0"
      "--system-call-filter=perf_event_open"
      "--system-call-filter=ptrace"
      "--system-call-filter=process_vm_readv"
      "--system-call-filter=process_vm_writev"
    ];
    # Replace nspawn's small tmpfs with private, disk-backed scratch space.
    bindMounts."/tmp" = {
      hostPath = "/var/lib/crow-ai/tmp";
      isReadOnly = false;
    };
    privateNetwork = true;
    localAddress = "10.80.0.2";
    hostAddress = "10.80.0.1";
    config = {
      imports = [ ../../nixos-modules/ai-container ];
      networking.hostName = "crow-ai";
      systemd.services.crow-ai-usb-dev-layout = {
        description = "Expose USB devices at their normal guest /dev paths";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStartPre = "${pkgs.python3}/bin/python3 -E -s ${./usb-dev-layout.py} --once";
          ExecStart = "${pkgs.python3}/bin/python3 -E -s ${./usb-dev-layout.py}";
          RuntimeDirectory = "crow-ai-usb-layout";
          RuntimeDirectoryPreserve = "yes";
          UMask = "0077";
          NoNewPrivileges = true;
          Restart = "on-failure";
          RestartSec = 1;
        };
      };
      # Sudo administers the guest within its remapped user namespace.
      security.sudo = {
        enable = lib.mkForce true;
        extraRules = [{
          users = [ "cody-ai" ];
          commands = [{ command = "ALL"; options = [ "NOPASSWD" ]; }];
        }];
      };
      programs.fuse.enable = true;
      virtualisation.docker.rootless = {
        enable = true;
        setSocketVariable = true;
      };
      # Also expose the socket to lingering user services, including Codex.
      environment.etc."environment.d/61-docker.conf".text = ''
        DOCKER_HOST=unix:///run/user/1001/docker.sock
      '';
      environment.etc."systemd/network/10-lan.network.d/90-hardware.conf".source = "/run/hardware-identities/90-hardware.conf";
      # L2 ipvlan shares the Wi-Fi station MAC and receives LAN broadcasts.
      systemd.network.networks."10-lan" = {
        matchConfig.Name = "iv-wlp6s0";
        networkConfig = { DHCP = "yes"; IPv6AcceptRA = true; };
        # Distinguish the guest's lease from the host despite their shared MAC.
        dhcpV4Config = {
          ClientIdentifier = "duid";
          SendHostname = true;
          # The ipvlan cannot receive unicast offers before it has an address.
          RequestBroadcast = true;
          RouteMetric = 600;
        };
        ipv6AcceptRAConfig.RouteMetric = 600;
        linkConfig.RequiredForOnline = "routable";
      };
      # Share the wired port without assigning a new hardware identity.
      systemd.network.networks."10-ethernet" = {
        matchConfig.Name = "iv-enp3s0";
        networkConfig = { DHCP = "yes"; IPv6AcceptRA = true; };
        dhcpV4Config = {
          ClientIdentifier = "duid";
          SendHostname = true;
          RequestBroadcast = true;
          RouteMetric = 100;
        };
        ipv6AcceptRAConfig.RouteMetric = 100;
        linkConfig.RequiredForOnline = false;
      };
      systemd.network.networks."10-ai" = {
        matchConfig.Name = "eth0";
        address = [ "10.80.0.2/24" ];
        networkConfig = { DHCP = "no"; IPv6AcceptRA = false; LinkLocalAddressing = "no"; };
        linkConfig.RequiredForOnline = false;
      };
      nixpkgs.pkgs = pkgs;
      # Allow all ports on the private link used by Tailscale's subnet route.
      networking.firewall.trustedInterfaces = [ "eth0" ];
    };
  };
  systemd.services."container@crow-ai" = {
    # Activate guest changes in place; container boundary changes need a restart.
    reloadIfChanged = true;
    unitConfig.RequiresMountsFor = [ "/var/lib/nixos-containers" ];
    # Stop the old "ai" instance before the renamed unit starts so its state is
    # no longer in use when preStart moves it.
    conflicts = [ "container@ai.service" ];
    preStart = ''
      # Preserve the old container state while renaming it away from the "ai"
      # machine name. Refuse to start a second copy if the old unit is live.
      if [ -d /var/lib/nixos-containers/ai ] && [ ! -e /var/lib/nixos-containers/crow-ai ]; then
        if ${pkgs.systemd}/bin/systemctl is-active --quiet container@ai.service; then
          echo "container@ai.service is still running; stop it before migrating state" >&2
          exit 1
        fi
        ${pkgs.coreutils}/bin/mv /var/lib/nixos-containers/ai /var/lib/nixos-containers/crow-ai
      fi
      # Keep container scratch private to the container boundary.
      ${pkgs.coreutils}/bin/install -d -m 0700 /var/lib/crow-ai
      ${pkgs.coreutils}/bin/install -d -m 1777 /var/lib/crow-ai/tmp
      # Inherited by new files: no data COW, checksums, or compression. Scope
      # this to disposable scratch; Btrfs mount tuning would affect the host.
      if [ "$(${pkgs.util-linux}/bin/findmnt -n -o FSTYPE -T /var/lib/crow-ai/tmp)" = btrfs ]; then
        ${pkgs.e2fsprogs}/bin/chattr +C /var/lib/crow-ai/tmp
      fi
    '';
  };
  # Override systemd's 80-container-ve.network, which otherwise replaces
  # hostAddress with an automatically selected DHCP-server subnet.
  systemd.network.networks."10-ai" = {
    matchConfig.Name = "ve-crow-ai";
    address = [ "10.80.0.1/24" ];
    networkConfig = { DHCP = "no"; DHCPServer = false; IPv6AcceptRA = false; LinkLocalAddressing = "no"; };
    linkConfig.RequiredForOnline = false;
  };
  # Advertise only the container, not the host or the rest of the private /24.
  services.tailscale.extraSetFlags = [ "--advertise-routes=10.80.0.2/32" ];

  networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [ 2223 ];
  networking.firewall.interfaces.wlp6s0.allowedTCPPorts = [ 2223 ];
  networking.firewall.interfaces.enp3s0.allowedTCPPorts = [ 2223 ];
  systemd.sockets.ai-container-ssh = {
    description = "AI container SSH over Crow LAN and Tailscale";
    # Listen independently of either interface; the firewall limits access.
    wantedBy = [ "sockets.target" ];
    socketConfig = {
      ListenStream = "2223";
      BindIPv6Only = "both";
    };
  };
  systemd.services.ai-container-ssh = {
    description = "Proxy LAN and Tailscale SSH connections to the AI container";
    requires = [ "container@crow-ai.service" ];
    # Drop the inherited listener when the socket stops.
    # Otherwise the old proxy prevents the replacement socket from starting.
    bindsTo = [ "ai-container-ssh.socket" ];
    after = [ "container@crow-ai.service" "ai-container-ssh.socket" ];
    serviceConfig = {
      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 10.80.0.2:22";
      DynamicUser = true;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
    };
  };
}
