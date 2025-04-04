{ config, lib, pkgs, ... }:
let
  cfg = config.services.tailscale;
in
{
  boot.initrd = {
    systemd.packages = [ cfg.package ];
    systemd.initrdBin = [ pkgs.iptables pkgs.iproute2 cfg.package ];
    availableKernelModules = [ "tun" "nft_chain_nat" ];

    systemd.services.tailscaled = {
      wantedBy = [ "initrd.target" ];
      serviceConfig.Environment = [
        "PORT=${toString cfg.port}"
        ''"FLAGS=--tun ${lib.escapeShellArg cfg.interfaceName}"''
      ];
    };


    systemd.tmpfiles.settings = {
      "50-tailscale" = {
        "/var/run".L = {
          argument = "/run";
        };
      };
    };

    systemd.network.networks."50-tailscale" = {
      matchConfig = {
        Name = cfg.interfaceName;
      };
      linkConfig = {
        Unmanaged = true;
        ActivationPolicy = "manual";
      };
    };

    systemd.extraBin.ping = "${pkgs.iputils}/bin/ping";

    #systemd.additionalUpstreamUnits = ["systemd-resolved.service"];
    #systemd.users.systemd-resolve = {};
    #systemd.groups.systemd-resolve = {};
    #systemd.contents."/etc/systemd/resolved.conf".source = config.environment.etc."systemd/resolved.conf".source;
    #systemd.storePaths = ["${config.boot.initrd.systemd.package}/lib/systemd/systemd-resolved"];
    systemd.services.systemd-resolved = {
      # Default is "sysinit.target", which is too late (blocks tailscaled)
      wantedBy = lib.mkForce [ "initrd.target" ];
      serviceConfig.ExecStartPre = "-+/bin/ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf";
    };
  };
}
