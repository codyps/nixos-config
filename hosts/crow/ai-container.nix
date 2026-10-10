{ config, lib, pkgs, ... }:
{
  # These controls are host-wide, not namespaced. Allow per-process profiling
  # (including kernel time) and debugger attachment to same-UID dumpable tasks.
  # System-wide perf and tracing other users still require privileges.
  boot.kernel.sysctl = {
    "kernel.perf_event_paranoid" = 1;
    "kernel.yama.ptrace_scope" = 0;
  };

  # Primary AI environment; no AI account or sandbox is created on the host.
  # /var/lib is persisted on Crow's encrypted /persist filesystem.
  containers.ai = {
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
    # Replace nspawn's small tmpfs with private, disk-backed scratch space.
    bindMounts."/tmp" = {
      hostPath = "/var/lib/crow-ai/tmp";
      isReadOnly = false;
    };
    privateNetwork = true;
    localAddress = "10.80.0.2";
    hostAddress = "10.80.0.1";
    config = {
      imports = [ ../warbler/ai-container-guest.nix ];
      networking.hostName = lib.mkForce "crow-ai";
      systemd.network.networks."10-lan".enable = false;
      systemd.network.networks."10-ai" = {
        matchConfig.Name = "eth0";
        address = [ "10.80.0.2/24" ];
        networkConfig = { DHCP = "no"; Gateway = "10.80.0.1"; IPv6AcceptRA = false; LinkLocalAddressing = "no"; };
        linkConfig.RequiredForOnline = "routable";
      };
      networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
      nixpkgs.pkgs = pkgs;
      # Allow all ports on the private link used by Tailscale's subnet route.
      networking.firewall.trustedInterfaces = [ "eth0" ];
    };
  };
  systemd.services."container@ai" = {
    # Activate guest changes in place; container boundary changes need a restart.
    reloadIfChanged = true;
    unitConfig.RequiresMountsFor = [ "/var/lib/nixos-containers" ];
    preStart = ''
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
  networking.nat = {
    enable = true;
    externalInterface = "wlp6s0";
    internalInterfaces = [ "ve-ai" ];
  };
  # Override systemd's 80-container-ve.network, which otherwise replaces
  # hostAddress with an automatically selected DHCP-server subnet.
  systemd.network.networks."10-ai" = {
    matchConfig.Name = "ve-ai";
    address = [ "10.80.0.1/24" ];
    networkConfig = { DHCP = "no"; DHCPServer = false; IPv6AcceptRA = false; LinkLocalAddressing = "no"; };
    linkConfig.RequiredForOnline = false;
  };
  # Advertise only the container, not the host or the rest of the private /24.
  services.tailscale.extraSetFlags = [ "--advertise-routes=10.80.0.2/32" ];

  networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [ 2223 ];
  systemd.sockets.ai-container-ssh = {
    description = "AI container SSH over Crow Tailscale";
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
    requires = [ "container@ai.service" ];
    # Drop the inherited listener before its bound interface/socket disappears.
    # Otherwise the old proxy prevents the replacement socket from starting.
    bindsTo = [ "ai-container-ssh.socket" ];
    after = [ "container@ai.service" "ai-container-ssh.socket" ];
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
