{ config, lib, pkgs, hardwareIdentities, ... }:
{
  # These controls are host-wide, not namespaced. Allow per-process profiling
  # (including kernel time) and debugger attachment to same-UID dumpable tasks.
  # System-wide perf and tracing other users still require privileges.
  boot.kernel.sysctl = {
    "kernel.perf_event_paranoid" = 1;
    "kernel.yama.ptrace_scope" = 0;
  };
  # The guest cannot load the host kernel modules needed by nested Docker.
  boot.kernelModules = [ "overlay" "bridge" "veth" "br_netfilter" "xt_nat" "ip_tables" "iptable_nat" ];

  # Primary AI environment; no AI account or sandbox is created on the host.
  # /var/lib is persisted on Crow's encrypted /persist filesystem.
  services.hardwareIdentities.templates."containers/warbler-ai/90-hardware.conf".text = ''
    [Link]
    MACAddress=${hardwareIdentities "warbler" [ "network" "containers" "warbler-ai" "interfaces" "mv-eno1" "macAddress" ]}
  '';
  containers.ai = {
    bindMounts."/run/hardware-identities" = {
      hostPath = "${config.services.hardwareIdentities.stateDirectory}/current/containers/warbler-ai";
      isReadOnly = true;
    };
    autoStart = true;
    restartIfChanged = false;
    ephemeral = false;
    # RootlessKit uses a TUN interface inside its user/network namespace.
    enableTun = true;
    # nspawn otherwise filters perf_event_open; explicitly permit debugging
    # syscalls too, without granting cody-ai capabilities or sudo access.
    extraFlags = [
      "--network-ipvlan=wlp6s0"
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
        };
        linkConfig.RequiredForOnline = "routable";
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
  networking.firewall.interfaces.wlp6s0.allowedTCPPorts = [ 2223 ];
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
    requires = [ "container@ai.service" ];
    # Drop the inherited listener when the socket stops.
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
