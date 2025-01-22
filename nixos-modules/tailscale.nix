{ config, pkgs, lib, ... }:
let
  # FIXME: determine which table tailscale uses
  # FIXME: support dynamic changes to the subnets (right now, if our address
  # changes, we don't rescan the routing table but we should. To both add-back
  # and remove addresses in respose to changes)
  tailscale-workaround-accept-routes = pkgs.writeShellApplication {
    name = "tailscale-workaround-accept-routes";
    runtimeInputs = [ pkgs.gawk pkgs.ipcalc pkgs.iproute2 ];
    text = builtins.readFile ./tailscale-workaround-accept-routes.sh;
  };
in

{
  # workaround tailscale accept-routes routing bug with local subnets
  # https://github.com/tailscale/tailscale/issues/1227

  options.services.tailscale.workaround-accept-routes = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "enable workaround for tailscale accept-routes bug";
    };
  };

  config = lib.mkIf (config.services.tailscale.enable && config.services.tailscale.workaround-accept-routes.enable) {
    # workaround tailscale accept-routes routing bug with local subnets
    systemd.services.tailscale-workaround-accept-routes = {
      description = "Workaround tailscale accept-routes routing bug with local subnets";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${tailscale-workaround-accept-routes}/bin/tailscale-workaround-accept-routes ${config.services.tailscale.interfaceName}";
      };

    };

  };

}
