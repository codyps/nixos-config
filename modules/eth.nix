{ config, pkgs, lib, ... }:
let
  holesky_jwt_path = "/persist/etc/ethereum/holesky-jwt";
  mainnet_jwt_path = "/persist/etc/ethereum/mainnet-jwt";
in
{
  environment.persistence."/persist" = {
    directories = [
      "/var/lib/private/geth-holesky"
      "/var/lib/private/lighthouse-holesky"
      "/var/lib/private/geth-mainnet"
      "/var/lib/private/lighthouse-mainnet"
    ];
  };

  services.ethereum.geth.holesky = {
    package = pkgs.geth;
    enable = true;
    openFirewall = true;
    args = {
      network = "holesky";
      authrpc.jwtsecret = holesky_jwt_path;
      #datadir = "/persist/var/lib/private/geth-holesky";

      port = 8550;
      authrpc.port = 8551;
      ws.port = 8552;
      metrics.port = 8553;
    };
    extraArgs = [
      "--metrics.influxdb"
      "--metrics.influxdb.tags"
      "network=holesky,host=ward"
    ];
  };

  services.ethereum.lighthouse-beacon.holesky = {
    enable = true;
    openFirewall = true;
    args = {
      network = "holesky";
      #datadir = "/persist/var/lib/private/lighthouse-holesky/beacon";
      execution-jwt = holesky_jwt_path;
      # services.ethereum.geth.holesky.args.authrpc.port
      execution-endpoint = "http://localhost:8551";
      checkpoint-sync-url = "https://checkpoint-sync.holesky.ethpandaops.io/";
      genesis-state-url = "https://checkpoint-sync.holesky.ethpandaops.io/";

      disable-upnp = false;
      port = 8554;
      quic-port = 8555;
      http.port = 8556;
      http.enable = true;
      metrics.port = 8557;
    };
  };

  services.ethereum.lighthouse-validator.holesky = {
    enable = true;
    openFirewall = true;
    args = {
      network = "holesky";
      #datadir = "/persist/var/lib/private/lighthouse-holesky/validator";
      # services.ethereum.lighthouse-beacon.holesky.args.http-port
      beacon-nodes = [ "http://localhost:8556" ];
      metrics.port = 8558;
    };
  };

  services.ethereum.geth.mainnet = {
    package = pkgs.geth;
    enable = true;
    openFirewall = true;
    args = {
      network = "mainnet";
      authrpc.jwtsecret = mainnet_jwt_path;
      #datadir = "/persist/var/lib/private/geth-mainnet";

      port = 8560;
      authrpc.port = 8561;
      ws.port = 8562;
      metrics.port = 8563;
    };
    extraArgs = [
      "--metrics.influxdb"
      "--metrics.influxdb.tags"
      "network=holesky,host=ward"
    ];
  };

  services.ethereum.lighthouse-beacon.mainnet = {
    enable = true;
    openFirewall = true;
    args = {
      network = "mainnet";
      #datadir = "/persist/var/lib/private/lighthouse-mainnet/beacon";
      execution-jwt = mainnet_jwt_path;
      # services.ethereum.geth.mainnet.args.authrpc.port
      execution-endpoint = "http://localhost:8561";
      checkpoint-sync-url = "https://sync.invis.tools/";
      genesis-state-url = "https://sync.invis.tools/";

      disable-upnp = false;
      port = 8564;
      quic-port = 8565;
      http.port = 8566;
      http.enable = true;
      metrics.port = 8567;
    };
  };

  services.ethereum.lighthouse-validator.mainnet = {
    enable = true;
    openFirewall = true;
    args = {
      network = "mainnet";
      #datadir = "/persist/var/lib/private/lighthouse-mainnet/validator";
      # services.ethereum.lighthouse-beacon.mainnet.args.http-port
      beacon-nodes = [ "http://localhost:8566" ];
      metrics.port = 8568;
    };
  };
}
