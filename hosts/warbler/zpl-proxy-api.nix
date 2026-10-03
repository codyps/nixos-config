{ config, ... }:
{
  sops.secrets.zpl-printers = {
    sopsFile = ./zpl-printers.enc.json;
    format = "binary";
    restartUnits = [ "zpl-proxy-api.service" ];
  };

  services.zpl-proxy-api = {
    enable = true;
    printersFile = config.sops.secrets.zpl-printers.path;
    listenAddress = "0.0.0.0";
    port = 3000;
    environment.OTEL_TRACES_EXPORTER = "none";
  };

  # Expose the preview API on the LAN and tailnet only.
  networking.firewall.interfaces.eno1.allowedTCPPorts = [ 3000 ];
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 3000 ];
  # The upstream StateDirectory lives under /var/lib, already persisted by warbler.
}
