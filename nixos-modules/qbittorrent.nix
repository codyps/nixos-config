# Taken from https://github.com/hercules-ci/nixflk/blob/1c5a86026be777de78eadd9903267f0093262af2/modules/services/torrent/qbittorrent.nix

{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.services.qbittorrent;
  configDir = "${cfg.dataDir}/.config";
  openFilesLimit = 4096;
  rootDir = "/run/qbittorrent";

  inherit (lib) mkOption types mkIf mkDefault;
in
{
  options.services.qbittorrent = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Run qBittorrent headlessly as systemwide daemon
      '';
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/qbittorrent";
      description = ''
        The directory where qBittorrent will create files.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "qbittorrent";
      description = ''
        User account under which qBittorrent runs.
      '';
    };

    group = mkOption {
      type = types.str;
      default = "qbittorrent";
      description = ''
        Group under which qBittorrent runs.
      '';
    };

    webui_port = mkOption {
      type = types.webui_port;
      default = 8080;
      description = ''
        qBittorrent web UI port.
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.qbittorrent-nox;
      description = ''
        The qBittorrent package to use.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open services.qBittorrent.webui_port to the outside network.
      '';
    };

    openFilesLimit = mkOption {
      default = openFilesLimit;
      description = ''
        Number of files to allow qBittorrent to open.
      '';
    };
  };

  config = mkIf cfg.enable {
    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.webui_port ];
      allowedUDPPorts = [ cfg.webui_port ];
    };

    systemd.services.qbittorrent = {
      description = "qBittorrent Daemon";
      wantedBy = [ "multi-user.target" ];
      script = ''
          ${cfg.package}/bin/qbittorrent-nox \
            --profile=${configDir} \
            --webui-port=${toString cfg.webui_port}
        '';
      serviceConfig = {
        Restart = "always";
        User = cfg.user;
        Group = cfg.group;
        UMask = "0002";
        LimitNOFILE = cfg.openFilesLimit;
        StateDirectory = "qbittorrent";
        RuntimeDirectory = [ (baseNameOf rootDir)];
        RuntimeDirectoryMode = "0755";
        UMask = "0066";

        RootDirectory = rootDir;
        RootDirectoryStartOnly = true;

        MountAPIVFS = true;

        BindPaths =
          [
            "${cfg.dataDir}"
            "/run"
          ];
        BindReadOnlyPaths = [
          builtins.storeDir
          "/etc"
        ];

        AmbientCapabilities = "";
        CapabilityBoundingSet = "";

        DeviceAllow = "";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateMounts = mkDefault true;
        PrivateNetwork = mkDefault false;
        PrivateTmp = true;
        PrivateUsers = mkDefault true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RemoveIPC = true;

        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];

        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;

        SystemCallArchitectures = "native";
      };
    };

    users.users = mkIf (cfg.user == "qbittorrent") {
      qbittorrent = {
        group = cfg.group;
        home = cfg.dataDir;
        createHome = true;
        description = "qBittorrent Daemon user";
      };
    };

    users.groups =
      mkIf (cfg.group == "qbittorrent") { qbittorrent = { gid = null; }; };
  };
}
