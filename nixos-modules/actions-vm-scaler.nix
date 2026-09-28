{ config, lib, pkgs, ... }:
let
  cfg = config.services.actions-vm-scaler;
  format = pkgs.formats.json { };
  package = pkgs.callPackage ../nixpkgs/actions-vm-scaler.nix { };
  taps = lib.genList (i: "avm${toString i}") cfg.capacity;
  mac = i: "52:54:00:78:00:${lib.fixedWidthString 2 "0" (lib.toHexString i)}";
  ip = i: "10.78.0.${toString (10 + i)}";
  stateDir = "/var/lib/actions-vm-scaler";
  runtimeConfig = format.generate "actions-vm-scaler.json" (cfg.settings // {
    state_dir = stateDir;
    private_key_file = "/run/credentials/actions-vm-scaler.service/github-app-key";
    vm = (cfg.settings.vm or { }) // {
      qemu = "${pkgs.qemu_kvm}/bin/qemu-system-x86_64";
      qemu_img = "${pkgs.qemu_kvm}/bin/qemu-img";
      xorriso = "${pkgs.xorriso}/bin/xorriso";
      inherit taps;
    };
  });
  networkSetup = pkgs.writeShellScript "actions-vm-network" ''
    set -eu
    ${pkgs.iproute2}/bin/ip link show avmbr0 >/dev/null 2>&1 || ${pkgs.iproute2}/bin/ip link add avmbr0 type bridge
    ${pkgs.iproute2}/bin/ip address replace 10.78.0.1/24 dev avmbr0
    ${pkgs.iproute2}/bin/ip link set avmbr0 up
    ${lib.concatMapStringsSep "\n" (tap: ''
      ${pkgs.iproute2}/bin/ip link show ${tap} >/dev/null 2>&1 || ${pkgs.iproute2}/bin/ip tuntap add dev ${tap} mode tap user actions-vm-scaler
      ${pkgs.iproute2}/bin/ip link set ${tap} master avmbr0
      ${pkgs.iproute2}/bin/ip link set ${tap} type bridge_slave isolated on
      ${pkgs.iproute2}/bin/ip link set ${tap} up
    '') taps}
  '';
in
{
  imports = [ ../modules/admin-commands.nix ];
  options.services.actions-vm-scaler = {
    enable = lib.mkEnableOption "disposable QEMU GitHub Actions runners";
    capacity = lib.mkOption {
      type = lib.types.ints.between 1 32;
      default = 1;
      description = "Maximum concurrent VMs across all discovered repositories; each gets a dedicated isolated TAP.";
    };
    privateKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime GitHub App PEM path, typically a SOPS secret. Never a Nix store path.";
    };
    settings = lib.mkOption {
      type = format.type;
      default = { };
      description = "Scaler JSON settings. Omit github_url to discover all repositories granted to the App installation. The module supplies executable, state, key and TAP paths.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      { assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux"; message = "actions-vm-scaler requires x86_64 Linux/KVM."; }
      { assertion = lib.hasPrefix "/" cfg.privateKeyFile && !(lib.hasPrefix builtins.storeDir cfg.privateKeyFile); message = "actions-vm-scaler privateKeyFile must be an absolute runtime secret path outside the Nix store."; }
    ];
    users.groups.actions-vm-scaler = { };
    users.users.actions-vm-scaler = {
      isSystemUser = true;
      group = "actions-vm-scaler";
      extraGroups = [ "kvm" ];
    };
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    networking.nftables = {
      enable = true;
      tables.actions-vm-isolation = {
        family = "inet";
        content = ''
          chain input {
            type filter hook input priority -10; policy accept;
            iifname "avmbr0" udp dport { 53, 67 } accept
            iifname "avmbr0" tcp dport 53 accept
            iifname "avmbr0" drop
          }
          chain forward {
            type filter hook forward priority -10; policy accept;
            iifname "avmbr0" meta nfproto ipv6 drop
            iifname "avmbr0" ip saddr != 10.78.0.0/24 drop
            iifname "avmbr0" ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } drop
            oifname "avmbr0" ct state established,related accept
            oifname "avmbr0" drop
          }
          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            ip saddr 10.78.0.0/24 oifname != "avmbr0" masquerade
          }
        '';
      };
      tables.actions-vm-antispoof = {
        family = "bridge";
        content = ''
          chain prerouting {
            type filter hook prerouting priority -300; policy accept;
            ${lib.concatStringsSep "\n" (lib.imap0 (i: tap: ''
              iifname "${tap}" ether saddr != ${mac i} drop
              iifname "${tap}" ether type ip6 drop
              iifname "${tap}" ether type ip ip saddr != { 0.0.0.0, ${ip i} } drop
              iifname "${tap}" ether type arp arp saddr ether != ${mac i} drop
              iifname "${tap}" ether type arp arp saddr ip != { 0.0.0.0, ${ip i} } drop
            '') taps)}
          }
        '';
      };
    };
    networking.firewall.interfaces.avmbr0 = {
      allowedTCPPorts = [ 53 ];
      allowedUDPPorts = [ 53 67 ];
    };
    networking.firewall.extraForwardRules = ''
      iifname "avmbr0" accept
      oifname "avmbr0" ct state established,related accept
    '';
    systemd.services.actions-vm-network = {
      description = "Private network for disposable Actions VMs";
      before = [ "actions-vm-scaler.service" "actions-vm-dhcp.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = networkSetup; };
    };
    systemd.services.actions-vm-dhcp = {
      requires = [ "actions-vm-network.service" ];
      after = [ "actions-vm-network.service" ];
      serviceConfig = {
        ExecStart = "${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --user=root --conf-file=/dev/null --interface=avmbr0 --bind-interfaces --except-interface=lo --dhcp-range=10.78.0.10,10.78.0.100,255.255.255.0,1h --dhcp-leasefile=/run/actions-vm-dhcp/leases --dhcp-option=3,10.78.0.1 --dhcp-option=6,10.78.0.1 ${lib.concatStringsSep " " (lib.imap0 (i: _: "--dhcp-host=${mac i},${ip i}") taps)}";
        RuntimeDirectory = "actions-vm-dhcp";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
    systemd.services.actions-vm-scaler = {
      description = "GitHub Actions macOS VM scale set";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      requires = [ "actions-vm-network.service" "actions-vm-dhcp.service" "nftables.service" ];
      after = [ "network-online.target" "actions-vm-network.service" "actions-vm-dhcp.service" "nftables.service" ];
      serviceConfig = {
        Type = "simple";
        User = "actions-vm-scaler";
        Group = "actions-vm-scaler";
        SupplementaryGroups = [ "kvm" ];
        ExecStart = "${package}/bin/actions-vm-scaler run ${runtimeConfig}";
        LoadCredential = [ "github-app-key:${cfg.privateKeyFile}" ];
        StateDirectory = "actions-vm-scaler";
        StateDirectoryMode = "0700";
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = 30;
        TimeoutStopSec = 40;
        KillMode = "mixed";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        RestrictSUIDSGID = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
        DevicePolicy = "closed";
        DeviceAllow = [ "/dev/kvm rw" "/dev/net/tun rw" ];
        LimitCORE = 0;
      };
    };
    programs.adminCommands.commands.actions-vm-scaler = [ "${package}/bin/actions-vm-scaler" ];
  };
}
