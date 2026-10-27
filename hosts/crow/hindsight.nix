{ config, lib, pkgs, ... }:
let
  # Exact upstream 0.10.2 manifest, verified from GHCR during migration.
  image = "ghcr.io/vectorize-io/hindsight@sha256:d1840062a5b79940ab7a9f4809ceb90fc776d4ad737cd9329e9b5836cc64ab70";
  readyFile = "/var/lib/hindsight/migration-ready";
  databaseSetup = pkgs.writeText "hindsight-database-setup.py" ''
    import os
    from pathlib import Path
    import psycopg2

    password = Path(os.environ["CREDENTIALS_DIRECTORY"], "database-password").read_text().strip()
    with psycopg2.connect(dbname="hindsight", user="postgres", host="/run/postgresql") as connection:
        with connection.cursor() as cursor:
            cursor.execute("ALTER ROLE hindsight WITH PASSWORD %s", (password,))
            for extension in ("vector", "pg_trgm", "btree_gin"):
                cursor.execute('CREATE EXTENSION IF NOT EXISTS "' + extension + '"')
  '';
in
{
  sops.secrets = {
    hindsight-llm-api-key = {
      sopsFile = ./hindsight-secrets.json;
      format = "json";
      key = "llm-api-key";
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
    HINDSIGHT_API_LLM_API_KEY=${config.sops.placeholder.hindsight-llm-api-key}
  '';

  # Crow persists all /var/lib on its encrypted /persist volume.
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_18;
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

  systemd.tmpfiles.rules = [
    "d /var/lib/hindsight 0700 root root -"
    # The pinned upstream image runs as UID/GID 1000, not root.
    "d /var/lib/hindsight/cache 0700 1000 1000 -"
    "d /var/lib/hindsight/backups 0700 root root -"
  ];
  virtualisation.oci-containers = {
    backend = "podman";
    containers.hindsight = {
      inherit image;
      # Launch only the API, built-in MCP and worker, not bundled Postgres/UI.
      entrypoint = "/app/api/.venv/bin/python";
      cmd = [ "/opt/hindsight-hotfix/start.py" ];
      environmentFiles = [ config.sops.templates.hindsight-environment.path ];
      environment = {
        HINDSIGHT_API_HOST = "127.0.0.1";
        HINDSIGHT_API_PORT = "18788";
        HINDSIGHT_API_WORKER_ID = "crow-hindsight";
        HINDSIGHT_API_LLM_PROVIDER = "deepseek";
        HINDSIGHT_API_LLM_BASE_URL = "https://api.deepseek.com";
        HINDSIGHT_API_LLM_MODEL = "deepseek-flash";
        HINDSIGHT_API_LLM_REASONING_EFFORT = "none";
        HINDSIGHT_API_LLM_EXTRA_BODY = builtins.toJSON { thinking.type = "disabled"; };
        HINDSIGHT_API_LLM_MAX_CONCURRENT = "8";
        HINDSIGHT_API_LLM_TIMEOUT = "120";
        HINDSIGHT_API_REFLECT_WALL_TIMEOUT = "600";
        HINDSIGHT_API_EMBEDDINGS_PROVIDER = "local";
        HINDSIGHT_API_EMBEDDINGS_LOCAL_MODEL = "BAAI/bge-small-en-v1.5";
        HINDSIGHT_API_EMBEDDINGS_LOCAL_FORCE_CPU = "true";
        HINDSIGHT_API_RERANKER_PROVIDER = "local";
        HINDSIGHT_API_RERANKER_LOCAL_MODEL = "cross-encoder/ms-marco-MiniLM-L-6-v2";
        HINDSIGHT_API_RERANKER_LOCAL_FORCE_CPU = "true";
        HINDSIGHT_API_RERANKER_LOCAL_BUCKET_BATCHING = "true";
        HF_HOME = "/var/cache/hindsight/huggingface";
        TORCH_HOME = "/var/cache/hindsight/torch";
        HF_HUB_DISABLE_TELEMETRY = "1";
        DO_NOT_TRACK = "1";
      };
      volumes = [
        "/var/lib/hindsight/cache:/var/cache/hindsight"
        "${./hindsight-hotfix}:/opt/hindsight-hotfix:ro"
      ];
      extraOptions = [
        "--network=host"
        "--cap-drop=ALL"
        "--security-opt=no-new-privileges"
        "--shm-size=1g"
      ];
    };
  };
  systemd.services.podman-hindsight = {
    requires = [ "hindsight-database.service" ];
    after = [ "hindsight-database.service" ];
    # Stage without a second worker mutating imported data before verification.
    unitConfig.ConditionPathExists = readyFile;
  };

  # Preserve the source server's authentication model, but expose it only
  # through the encrypted tailnet. Neither API nor DB listens on LAN/public IPs.
  systemd.services.hindsight-tailnet = {
    description = "Expose loopback Hindsight only through Tailscale Serve";
    wantedBy = [ "multi-user.target" ];
    wants = [ "tailscaled.service" "podman-hindsight.service" ];
    after = [ "tailscaled.service" "podman-hindsight.service" ];
    unitConfig.ConditionPathExists = readyFile;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Raw TCP preserves original HTTP Host headers from compatibility relays;
      # Tailscale's HTTP virtual-host proxy rejects localhost Host headers.
      ExecStart = "${pkgs.tailscale}/bin/tailscale serve --bg --tcp=18788 tcp://127.0.0.1:18788";
      ExecStop = "${pkgs.tailscale}/bin/tailscale serve --tcp=18788 off";
      Restart = "on-failure";
      RestartSec = "10s";
    };
  };
}
