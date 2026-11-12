{ config, lib, pkgs, ... }:
let
  # Sealed with the same PCR 7 (Secure Boot policy) binding as the
  # secure-unlock credentials; only ciphertext exists on disk.
  sealedStore = "${config.boot.secureUnlock.stateDirectory}/credstore.encrypted";
  credentialsDirectory = "/run/restic-backup-credentials";
  backupKeys = pkgs.writeShellApplication {
    name = "crow-backup-keys";
    runtimeInputs = with pkgs; [ python3 config.systemd.package ];
    text = ''
      exec python3 ${./backup-keys.py} "$@"
    '';
  };
in
{
  sops.secrets = {
    restic-repository-endpoint = {
      sopsFile = ./backup-secrets.yaml;
      restartUnits = [ "restic-backup-credentials.service" ];
    };
    restic-repository-username = {
      sopsFile = ./backup-secrets.yaml;
      restartUnits = [ "restic-backup-credentials.service" ];
    };
  };

  # Persistent state and homes go to the TrueNAS restic REST server. The live
  # PostgreSQL cluster is excluded on purpose; restic captures the daily dumps
  # in /var/lib/postgresql-backups instead. Backup runs wait for the repository
  # lock rather than failing the night.
  services.restic.backups.truenas = {
    paths = [ "/persist" "/home" ];
    exclude = [
      "/home/*/.cache"
      "/persist/credstore"
      "/persist/credstore.encrypted"
      "/persist/var/lib/dedupit"
      "/persist/var/lib/hindsight/cache"
      "/persist/var/lib/postgresql"
    ];
    passwordFile = "${credentialsDirectory}/restic-password";
    repositoryFile = "${credentialsDirectory}/repository";
    initialize = true;
    # Other hosts share this repository (some managed by backrest, which
    # identifies snapshots via plan:<id> and created-by:<instance> tags).
    # Tag Crow's snapshots backrest-compatibly; retention is host-scoped in
    # the separate weekly prune job so forget never touches other hosts.
    extraBackupArgs = [ "--tag plan:crow" "--tag created-by:crow" "--retry-lock 30m" ];
    timerConfig = {
      OnCalendar = "02:30";
      RandomizedDelaySec = "45m";
      Persistent = true;
    };
  };

  # Weekly retention: forget/prune takes an exclusive lock over the shared
  # repository, so it runs in its own staggered window, scoped to this host,
  # and waits for the lock instead of failing. A prune-only job (no paths).
  services.restic.backups.truenas-prune = {
    passwordFile = "${credentialsDirectory}/restic-password";
    repositoryFile = "${credentialsDirectory}/repository";
    pruneOpts = [ "--retry-lock 60m" "--host crow" "--keep-daily 7" "--keep-weekly 5" "--keep-monthly 12" "--keep-yearly 3" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 04:30:00";
      RandomizedDelaySec = "15m";
      Persistent = true;
    };
  };

  # Unseal the TPM credentials at boot and compose the repository URL. The
  # service fails closed unless Secure Boot is enabled, so the backup can
  # never run with plaintext fallbacks or a stale unsealed key.
  systemd.services.restic-backup-credentials = {
    description = "Unseal TPM restic credentials and compose the repository URL";
    wantedBy = [ "multi-user.target" ];
    wants = [ "tpm2.target" ];
    after = [ "sops-nix.service" "tpm2.target" ];
    unitConfig = {
      RequiresMountsFor = [ config.boot.secureUnlock.stateDirectory ];
      ConditionSecurity = "uefi-secureboot";
      # Skip cleanly before provisioning instead of failing activation;
      # the backup unit requires this one, so it stays blocked until both
      # sealed credentials exist.
      ConditionPathExists = [
        "${sealedStore}/restic-password"
        "${sealedStore}/rest-server-password"
      ];
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${backupKeys}/bin/crow-backup-keys service";
      RuntimeDirectory = "restic-backup-credentials";
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
      LoadCredential = [
        "restic-repository-endpoint:${config.sops.secrets.restic-repository-endpoint.path}"
        "restic-repository-username:${config.sops.secrets.restic-repository-username.path}"
      ];
      LoadCredentialEncrypted = [
        "restic-password:${sealedStore}/restic-password"
        "rest-server-password:${sealedStore}/rest-server-password"
      ];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };

  systemd.services.restic-backups-truenas = {
    requires = [ "restic-backup-credentials.service" ];
    after = [ "restic-backup-credentials.service" "postgresqlBackup.service" ];
    # Never attempt a backup before the sealed credentials exist.
    unitConfig.ConditionPathExists = [
      "${sealedStore}/restic-password"
      "${sealedStore}/rest-server-password"
    ];
    serviceConfig = {
      UMask = "0077";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
    };
  };

  systemd.services."restic-backups-truenas-prune" = {
    requires = [ "restic-backup-credentials.service" ];
    after = [ "restic-backup-credentials.service" ];
    # Never run before the sealed credentials exist.
    unitConfig.ConditionPathExists = [
      "${sealedStore}/restic-password"
      "${sealedStore}/rest-server-password"
    ];
    serviceConfig = {
      UMask = "0077";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
    };
  };

  programs.adminCommands.commands = {
    setup-backup-keys = [ "${backupKeys}/bin/crow-backup-keys" ];
    backup-now = [ "${config.systemd.package}/bin/systemctl" "start" "restic-backups-truenas.service" ];
  };
}
