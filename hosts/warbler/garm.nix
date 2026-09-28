{ config, lib, pkgs, ... }:
let
  packages = pkgs.callPackage ../../nixpkgs/garm.nix { };
  toml = pkgs.formats.toml { };
  providerConfig = toml.generate "garm-incus.toml" {
    unix_socket_path = "/var/lib/incus/unix.socket";
    include_default_profile = false;
    instance_type = "virtual-machine";
    secure_boot = false;
    project_name = "garm";
    image_remotes.images = {
      addr = "https://images.linuxcontainers.org";
      public = true;
      protocol = "simplestreams";
      skip_verify = false;
    };
  };
  controllerConfig = toml.generate "garm-config-template.toml" {
    default.enable_webhook_management = false;
    logging = { log_format = "text"; log_level = "info"; };
    metrics = { enable = true; disable_auth = false; };
    jwt_auth = { secret = "@JWT_SECRET@"; time_to_live = "24h"; };
    apiserver = {
      bind = "127.0.0.1";
      port = 9997;
      use_tls = false;
      webui.enable = true;
    };
    database = {
      backend = "sqlite3";
      passphrase = "@DATABASE_KEY@";
      sqlite3 = { db_file = "/var/lib/garm/garm.db"; busy_timeout_seconds = 5; };
    };
    provider = [{
      name = "incus";
      provider_type = "external";
      description = "Disposable Warbler KVM runners";
      external = {
        config_file = toString providerConfig;
        provider_executable = "${packages.provider}/bin/garm-provider-incus";
      };
    }];
  };
  admin = pkgs.writeShellScript "garm-admin" ''
    exec ${pkgs.python3}/bin/python3 ${./garm-admin.py} ${packages.cli}/bin/garm-cli "$@"
  '';
in
{
  imports = [ ../../modules/admin-commands.nix ./garm-cache.nix ];

  sops.secrets.garm-app-key = {
    sopsFile = ./garm-app-key.enc.json;
    format = "binary";
  };

  virtualisation.incus = {
    enable = true;
    preseed = {
      # Uses a directory on the existing Btrfs filesystem; no disk repartitioning.
      storage_pools = [{
        name = "garm";
        driver = "dir";
        config.source = "/var/lib/incus/storage-pools/garm";
      }];
      projects = [{
        name = "garm";
        config = {
          "features.images" = "true";
          "features.profiles" = "true";
          "features.networks" = "false";
          "limits.instances" = "2";
          "limits.virtual-machines" = "2";
          "limits.containers" = "0";
        };
      }];
      networks = [{
        name = "garm0";
        type = "bridge";
        config = {
          "ipv4.address" = "10.77.0.1/24";
          "ipv4.nat" = "true";
          "ipv6.address" = "none";
        };
      }];
      profiles = [{
        name = "runner";
        project = "garm";
        config = { "limits.cpu" = "4"; "limits.memory" = "8GiB"; };
        devices = {
          root = { type = "disk"; path = "/"; pool = "garm"; size = "40GiB"; };
          eth0 = {
            type = "nic";
            name = "eth0";
            network = "garm0";
            "security.mac_filtering" = "true";
            "security.ipv4_filtering" = "true";
            "security.ipv6_filtering" = "true";
            "security.port_isolation" = "true";
          };
        };
      }];
    };
  };

  networking.nftables = {
    enable = true;
    tables.garm-isolation = {
      family = "inet";
      content = ''
        chain input {
          type filter hook input priority -10; policy accept;
          iifname "garm0" udp dport { 53, 67 } accept
          iifname "garm0" tcp dport { 53, 9998, 9443 } accept
          iifname "garm0" drop
        }
        chain forward {
          type filter hook forward priority -10; policy accept;
          iifname "garm0" meta nfproto ipv6 drop
          iifname "garm0" ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } drop
        }
      '';
    };
  };
  networking.firewall.interfaces.garm0 = {
    allowedTCPPorts = [ 53 9998 9443 ];
    allowedUDPPorts = [ 53 67 ];
  };

  # Guests can reach only their authenticated bootstrap/callback endpoints.
  # The admin API and first-run endpoint remain on loopback, accessible via SSH.
  services.nginx = {
    enable = true;
    virtualHosts.garm-guests = {
      listen = [{ addr = "10.77.0.1"; port = 9998; }];
      locations = {
        "/".return = "404";
        "~ ^/(api/v1/(metadata|callbacks)(/|$)|agent(/|$))" = {
          proxyPass = "http://127.0.0.1:9997";
          proxyWebsockets = true;
        };
      };
    };
  };
  systemd.services.nginx = {
    requires = [ "incus-preseed.service" ];
    after = [ "incus-preseed.service" ];
  };

  users.groups.garm = { };
  users.users.garm = {
    isSystemUser = true;
    group = "garm";
    extraGroups = [ "incus-admin" ];
    home = "/var/lib/garm";
  };
  systemd.services.garm = {
    description = "GitHub Actions Runner Manager";
    wantedBy = [ "multi-user.target" ];
    requires = [ "incus-preseed.service" ];
    wants = [ "network-online.target" ];
    after = [ "incus-preseed.service" "network-online.target" ];
    path = [ pkgs.cacert ];
    environment.SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    preStart = ''
      ${pkgs.python3}/bin/python3 ${./garm-secrets.py} ${controllerConfig}
    '';
    serviceConfig = {
      User = "garm";
      Group = "garm";
      StateDirectory = "garm";
      StateDirectoryMode = "0700";
      RuntimeDirectory = "garm";
      RuntimeDirectoryMode = "0700";
      WorkingDirectory = "/var/lib/garm";
      ExecStart = "${packages.garm}/bin/garm -config /run/garm/config.toml";
      Restart = "on-failure";
      RestartSec = 5;
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
    };
  };

  environment.systemPackages = [ packages.cli ];
  programs.adminCommands.commands.garm = [ (toString admin) ];
}
