{ config, pkgs, ... }:
{
  # Alternate environment: do not mount or migrate the host AI account's home.
  # /var/lib is already persisted on Warbler's encrypted /persist filesystem.
  containers.ai = {
    autoStart = true;
    ephemeral = false;
    privateNetwork = true;
    macvlans = [ "eno1" ];
    # A private link avoids macvlan's host/guest isolation without
    # changing the guest's LAN default route or depending on its DHCP lease.
    extraVeths.ai-ssh = { };
    config = {
      imports = [ ./ai-container-guest.nix ];
      nixpkgs.pkgs = pkgs;
      networking.interfaces.ai-ssh.ipv4.addresses = [{ address = "10.79.0.2"; prefixLength = 24; }];
    };
  };
  systemd.services."container@ai".unitConfig.RequiresMountsFor = [ "/var/lib/nixos-containers" ];
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
