{ config, pkgs, ... }:
{
  # Primary AI environment: keep its persistent home separate from the legacy host home.
  # /var/lib is already persisted on Warbler's encrypted /persist filesystem.
  containers.ai = {
    autoStart = true;
    restartIfChanged = false;
    ephemeral = false;
    # Replace nspawn's small tmpfs with private, disk-backed scratch space.
    bindMounts."/tmp" = {
      hostPath = "/var/lib/warbler-ai/tmp";
      isReadOnly = false;
    };
    privateNetwork = true;
    macvlans = [ "eno1" ];
    # A private link avoids macvlan's host/guest isolation without
    # changing the guest's LAN default route or depending on its DHCP lease.
    extraVeths.ai-ssh = { };
    config = {
      imports = [ ./ai-container-guest.nix ];
      nixpkgs.pkgs = pkgs;
      networking.interfaces.ai-ssh.ipv4.addresses = [{ address = "10.79.0.2"; prefixLength = 24; }];
      # Allow all ports on the private link used by Tailscale's subnet route.
      networking.firewall.trustedInterfaces = [ "ai-ssh" ];
    };
  };
  systemd.services."container@ai" = {
    # Activate guest changes in place; container boundary changes need a restart.
    reloadIfChanged = true;
    unitConfig.RequiresMountsFor = [ "/var/lib/nixos-containers" ];
    preStart = ''
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
    wantedBy = [ "sockets.target" ];
    socketConfig = {
      ListenStream = "2223";
      BindToDevice = config.services.tailscale.interfaceName;
      BindIPv6Only = "both";
    };
  };
  systemd.services.ai-container-ssh = {
    description = "Proxy Tailscale SSH connections to the AI container";
    requires = [ "container@ai.service" ];
    after = [ "container@ai.service" ];
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
