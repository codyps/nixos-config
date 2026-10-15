{ lib, pkgs, ... }:
let
  image = "docker.io/rmcrackan/libation:latest";
  volumes = [
    "/ward/keep/libation/data:/data"
    "/ward/keep/libation/config:/config"
  ];
  environment = {
    SLEEP_TIME = "2h";
    # Read and save credentials directly on the persistent volume. The image's
    # default /config-internal is discarded whenever the container is replaced.
    LIBATION_FILES_DIR = "/config";
    LIBATION_MASTER_KEY_FILE = "/config/libation-master.key";
  };
  arguments = lib.escapeShellArgs (
    [ "--rm" "--pull=missing" ]
    ++ map (volume: "--volume=${volume}") volumes
    ++ lib.mapAttrsToList (name: value: "--env=${name}=${value}") environment
  );
  cli = pkgs.writeShellApplication {
    name = "libation-cli";
    runtimeInputs = [ pkgs.coreutils pkgs.podman pkgs.util-linux pkgs.systemd ];
    text = ''
      if [[ $(id -u) != 0 ]]; then
        echo 'Run this command with sudo.' >&2
        exit 1
      fi
      if systemctl is-active --quiet libation.service; then
        echo 'Stop libation.service before changing its account settings.' >&2
        exit 1
      fi
      exec 9>/run/libation-cli.lock
      flock --nonblock 9
      terminal=()
      if [[ -t 0 && -t 1 ]]; then
        terminal=(--interactive --tty)
      fi
      exec podman run ${arguments} --user "$(id -u libation):$(id -g libation)" \
        "''${terminal[@]}" --entrypoint /libation/LibationCli ${lib.escapeShellArg image} \
        "$@" --libationFiles /config
    '';
  };
  login = pkgs.writeShellApplication {
    name = "libation-login";
    runtimeInputs = [ pkgs.coreutils pkgs.jq pkgs.systemd ];
    text = ''
      systemctl stop libation.service
      config=/ward/keep/libation/config
      account=$(jq -er '.Accounts | if length == 1 then .[0].AccountId else error("Use sys libation-cli login-external with an explicit account and locale") end' "$config/AccountsSettings.json")
      locale=$(jq -er '.Accounts[0].IdentityTokens.LocaleName' "$config/AccountsSettings.json")
      # login-external trusts locally valid token fields even when Audible
      # rejects their refresh token. Back up the account and clear only its
      # stale identity, preserving library records and account preferences.
      backup=$(mktemp -d /ward/keep/libation/.login-backup.XXXXXXXX)
      install -m 0600 "$config/AccountsSettings.json" "$backup/AccountsSettings.json"
      install -m 0600 "$config/libation-master.key" "$backup/libation-master.key"
      restore_account() {
        install -o libation -g libation -m 0600 "$backup/AccountsSettings.json" "$config/AccountsSettings.json"
      }
      trap restore_account EXIT
      # Keep the locale so Libation updates this row instead of adding another.
      jq '.Accounts[0].IdentityTokens = {LocaleName: .Accounts[0].IdentityTokens.LocaleName}' "$backup/AccountsSettings.json" > "$backup/new-account.json"
      install -o libation -g libation -m 0600 "$backup/new-account.json" "$config/AccountsSettings.json"
      ${cli}/bin/libation-cli login-external --account "$account" --locale "$locale" "$@"
      trap - EXIT
      systemctl reset-failed libation.service
      systemctl start libation.service
    '';
  };
in
{
  imports = [ ../../modules/admin-commands.nix ];

  users.users.libation = {
    isSystemUser = true;
    group = "libation";
  };
  users.groups.libation = { };

  programs.adminCommands.commands = {
    libation-cli = [ "${cli}/bin/libation-cli" ];
    libation-login = [ "${login}/bin/libation-login" ];
  };

  systemd.services.libation = {
    unitConfig.RequiresMountsFor = [ "/ward/keep/libation" ];
    # Authentication failures should remain visible and retry at the usual scan
    # interval, rather than hammering Audible and hitting systemd's start limit.
    serviceConfig.RestartSec = "2h";
    preStart = ''
      ${pkgs.coreutils}/bin/chown -R libation:libation /ward/keep/libation
      ${pkgs.coreutils}/bin/chmod 0700 /ward/keep/libation/config
      key=/ward/keep/libation/config/libation-master.key
      if [ ! -e "$key" ]; then
        (umask 077; ${pkgs.coreutils}/bin/head -c 32 /dev/urandom > "$key")
      fi
      ${pkgs.coreutils}/bin/chown libation:libation "$key"
      ${pkgs.coreutils}/bin/chmod 0600 "$key"
    '';
    # Resolve the host's numeric UID/GID; these names do not exist in the image.
    script = lib.mkForce ''
      exec ${pkgs.podman}/bin/podman run ${arguments} \
        --name=libation --log-driver=journald --cidfile=/run/libation/ctr-id \
        --cgroups=enabled --sdnotify=conmon -d --replace \
        --user "$(${pkgs.coreutils}/bin/id -u libation):$(${pkgs.coreutils}/bin/id -g libation)" \
        -l io.containers.autoupdate=registry ${lib.escapeShellArg image}
    '';
  };

  virtualisation.oci-containers.containers.libation = {
    inherit image volumes environment;
    serviceName = "libation";
    user = "libation:libation";
    labels."io.containers.autoupdate" = "registry";
  };
}
