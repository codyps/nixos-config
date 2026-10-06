{ config, lib, pkgs, ... }:
let
  # Upstream 0.10.2 multi-platform manifest, verified against GHCR.
  image = "ghcr.io/vectorize-io/hindsight@sha256:d1840062a5b79940ab7a9f4809ceb90fc776d4ad737cd9329e9b5836cc64ab70";
  providerFile = "/var/lib/hindsight/provider.env";
  databaseSetup = pkgs.writeText "hindsight-database-setup.py" ''
    import os
    from pathlib import Path
    import psycopg2

    password = Path(os.environ["CREDENTIALS_DIRECTORY"], "database-password").read_text().strip()
    with psycopg2.connect(dbname="hindsight", user="postgres", host="/run/postgresql") as connection:
        with connection.cursor() as cursor:
            cursor.execute("ALTER ROLE hindsight WITH PASSWORD %s", (password,))
            cursor.execute("CREATE EXTENSION IF NOT EXISTS vector")
            cursor.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
  '';
in
{
  sops.secrets = {
    hindsight-api-key = {
      sopsFile = ./hindsight-secrets.json;
      format = "json";
      key = "api-key";
      restartUnits = [ "podman-hindsight.service" ];
    };
    hindsight-database-password = {
      sopsFile = ./hindsight-secrets.json;
      format = "json";
      key = "database-password";
      restartUnits = [ "hindsight-database.service" "podman-hindsight.service" ];
    };
  };
  sops.templates.hindsight-environment.content = ''
    HINDSIGHT_API_DATABASE_URL=postgresql://hindsight:${config.sops.placeholder.hindsight-database-password}@127.0.0.1:5432/hindsight
    HINDSIGHT_API_TENANT_API_KEY=${config.sops.placeholder.hindsight-api-key}
    HINDSIGHT_API_MCP_AUTH_TOKEN=${config.sops.placeholder.hindsight-api-key}
  '';

  # Warbler persists /var/lib on its encrypted /persist filesystem.
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17;
    extensions = ps: [ ps.pgvector ];
    enableTCPIP = true;
    settings.listen_addresses = lib.mkForce "127.0.0.1";
    ensureDatabases = [ "hindsight" ];
    ensureUsers = [{ name = "hindsight"; ensureDBOwnership = true; }];
    authentication = lib.mkBefore ''
      host hindsight hindsight 127.0.0.1/32 scram-sha-256
    '';
  };
  services.postgresqlBackup = {
    enable = true;
    databases = [ "hindsight" ];
    location = "/var/lib/postgresql-backups";
    startAt = "daily";
  };
  systemd.services.hindsight-database = {
    description = "Prepare Hindsight database credentials and extensions";
    requires = [ "postgresql.target" ];
    after = [ "postgresql.target" "sops-nix.service" ];
    before = [ "podman-hindsight.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
      LoadCredential = "database-password:${config.sops.secrets.hindsight-database-password.path}";
      ExecStart = "${pkgs.python3.withPackages (ps: [ ps.psycopg2 ])}/bin/python3 ${databaseSetup}";
    };
  };

  systemd.tmpfiles.rules = [ "d /var/lib/hindsight 0700 root root -" ];
  virtualisation.oci-containers = {
    backend = "podman";
    containers.hindsight = {
      inherit image;
      # Use only the API, including its built-in MCP and background worker.
      entrypoint = "/app/api/.venv/bin/hindsight-api";
      cmd = [ "--host" "0.0.0.0" "--port" "8888" ];
      environmentFiles = [
        providerFile
        config.sops.templates.hindsight-environment.path
      ];
      environment = {
        HINDSIGHT_API_HOST = "0.0.0.0";
        HINDSIGHT_API_PORT = "8888";
        HINDSIGHT_API_WORKER_ID = "warbler-hindsight";
        HINDSIGHT_API_LLM_PROVIDER = "openai";
        HINDSIGHT_API_LLM_MODEL = "gpt-5.4-mini";
        HINDSIGHT_API_TENANT_EXTENSION = "hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension";
        HINDSIGHT_API_TENANT_MCP_AUTH_DISABLED = "false";
        HINDSIGHT_API_MCP_ENABLED = "true";
        HINDSIGHT_API_MCP_STATELESS = "true";
        HINDSIGHT_API_EMBEDDINGS_PROVIDER = "local";
        HINDSIGHT_API_EMBEDDINGS_LOCAL_MODEL = "BAAI/bge-small-en-v1.5";
        HINDSIGHT_API_RERANKER_PROVIDER = "local";
        HINDSIGHT_API_OTEL_TRACES_ENABLED = "false";
        HF_HUB_DISABLE_TELEMETRY = "1";
        DO_NOT_TRACK = "1";
      };
      extraOptions = [
        "--network=host"
        "--cap-drop=ALL"
        "--security-opt=no-new-privileges"
        "--shm-size=1g"
      ];
    };
  };
  systemd.services.podman-hindsight = {
    requires = [ "hindsight-database.service" "nftables.service" ];
    after = [ "hindsight-database.service" "nftables.service" ];
    # Do not launch an unconfigured extraction backend. Provision via SOPS.
    unitConfig.ConditionPathExists = providerFile;
  };

  networking.firewall.interfaces = {
    ${config.services.tailscale.interfaceName}.allowedTCPPorts = [ 8888 ];
    ai-ssh.allowedTCPPorts = [ 8888 ];
  };
  # Host networking avoids a container port-forward bypass of the host firewall.
  # This independent chain also excludes otherwise trusted VM/LAN interfaces.
  networking.nftables = {
    enable = true;
    tables.hindsight-isolation = {
      family = "inet";
      content = ''
        chain input {
          type filter hook input priority -20; policy accept;
          iifname != { "lo", "${config.services.tailscale.interfaceName}", "ai-ssh" } tcp dport 8888 drop
        }
      '';
    };
  };
}
