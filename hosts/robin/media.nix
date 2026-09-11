{ pkgs, ... }:
let
  libationImage = "docker.io/rmcrackan/libation@sha256:4372b59e0c2a069212623770ff0bb48a74e43d6f2ed9a1388af347505f0dcc0a";
in
{
  # Preserve Finch's paths and identities so library records and peers survive.
  services.syncthing = {
    enable = true;
    dataDir = "/tank/syncthing";
    configDir = "/tank/syncthing/.config/syncthing";
    overrideDevices = false;
    overrideFolders = false;
  };
  systemd.services.syncthing.unitConfig.RequiresMountsFor = [ "/tank/syncthing" ];

  # User activation resets the home mode; restore only Caddy traversal afterward.
  systemd.tmpfiles.rules = [
    "a+ /tank/syncthing - - - - u:caddy:--x,m::--x"
  ];

  services.audiobookshelf = {
    enable = true;
    package = pkgs.audiobookshelf-headless;
    port = 8917;
  };
  users.users.audiobookshelf.uid = 992;
  users.groups.audiobookshelf.gid = 990;
  # Match the compiled web client's asset prefix and OIDC callback validation.
  systemd.services.audiobookshelf.environment.ROUTER_BASE_PATH = "/audiobookshelf";
  systemd.services.audiobookshelf.unitConfig.RequiresMountsFor = [
    "/tank/libation/data" "/tank/books/kindle" "/tank/books/personal"
  ];

  virtualisation.podman.enable = true;
  virtualisation.containers.policy = {
    default = [ { type = "reject"; } ];
    transports.docker.${libationImage} = [ { type = "insecureAcceptAnything"; } ];
  };
  virtualisation.oci-containers.containers.libation = {
    # The image deployed on Finch; upgrade independently of the host move.
    image = libationImage;
    autoStart = false;
    volumes = [
      "/tank/libation/data:/data"
      "/tank/libation/config:/config"
      "/tank/libation/tmp:/tmp"
    ];
  };
  systemd.services.podman-libation = {
    unitConfig.RequiresMountsFor = [ "/tank/libation" ];
    # Keep Type=notify: conmon tracks completion of the detached container.
    # Type=oneshot would finish after `podman run -d` and force-remove it.
  };
  systemd.timers.podman-libation = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      Persistent = true;
      OnCalendar = "hourly";
      AccuracySec = "30m";
      RandomizedDelaySec = "20m";
    };
  };

  services.caddy.virtualHosts."robin.little-moth.ts.net".extraConfig = ''
    tls {
      get_certificate tailscale
    }

    @outside not remote_ip 100.64.0.0/10 fd7a:115c:a1e0::/48 127.0.0.1 ::1
    respond @outside 403

    handle_path /roms/* {
      root /tank/syncthing/Roms
      file_server browse
    }
    handle_path /syncthing/* {
      reverse_proxy 127.0.0.1:8384 {
        header_up Host localhost
      }
    }
    handle {
      abort
    }
  '';

  environment.systemPackages = [ pkgs.rsync ];
  services.tailscale.useRoutingFeatures = "server";
  services.tailscale.extraSetFlags = [ "--advertise-exit-node" ];
}
