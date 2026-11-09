{ config, lib, pkgs, ... }:
let
  cfg = config.containers.crow-ai;
  guest = cfg.config;
  # Reserve 1M IDs: nested rootless Docker needs more than nspawn's default 64K.
  uidBase = 1048576;
  uidCount = 1048576;
  privateNix = "/var/lib/crow-ai/nix";
  userNamespaceFlags = [
    "--private-users=${toString uidBase}:${toString uidCount}"
    "--private-users-ownership=map"
  ];
  guestEntry = pkgs.writeShellScript "crow-ai-init" ''
    set -euo pipefail
    export NIX_REMOTE=local
    ${pkgs.nix}/bin/nix-store --option build-users-group "" --load-db < /run/crow-nix-closure/registration
    ${pkgs.nix}/bin/nix-env --option build-users-group "" --profile /nix/var/nix/profiles/system --set ${cfg.path}
    ${pkgs.coreutils}/bin/mkdir -p /nix/var/nix/gcroots
    ${pkgs.coreutils}/bin/ln -sfn "$0" /nix/var/nix/gcroots/crow-runtime
    # The standard NixOS container wrapper normally renames this interface.
    ${pkgs.iproute2}/bin/ip link set host0 name eth0
    unset NIX_REMOTE
    exec ${cfg.path}/init
  '';
  closure = pkgs.closureInfo { rootPaths = [ guestEntry ]; };
  seed = pkgs.writeShellScript "crow-ai-seed-nix" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    ${builtins.readFile ./ai-container-seed-nix.sh}
  '';
  bindFlags = lib.mapAttrsToList
    (name: mount:
      let
        flag = if mount.isReadOnly then "--bind-ro" else "--bind";
        source = if mount.hostPath == null then mount.mountPoint else mount.hostPath;
        # The scratch filesystem and root-only hardware template need their
        # original ownership translated. Device nodes already have mapped UIDs.
        mapping = lib.optionalString (name == "/tmp" || name == "/run/hardware-identities") ":idmap";
      in
      "${flag}=${source}:${mount.mountPoint}${mapping}"
    )
    cfg.bindMounts;
  run = pkgs.writeShellScript "crow-ai-start" ''
    set -euo pipefail
    # Only initialise a fresh root; never traverse an existing guest tree as
    # host root to seed its store. All copying happens in the user namespace.
    if [ ! -e "$root" ]; then
      ${pkgs.coreutils}/bin/mkdir -p "$root/etc"
      ${pkgs.coreutils}/bin/touch "$root/etc/os-release"
    fi
    ${pkgs.systemd}/bin/systemd-nspawn \
      --quiet --keep-unit --register=no --settings=no --private-network --notify-ready=yes \
      --directory="$root" ${lib.escapeShellArgs userNamespaceFlags} \
      --bind-ro=/nix/store:/nix/store:idmap \
      --bind-ro=${closure}:/run/crow-nix-closure:idmap \
      --bind=${privateNix}:/run/crow-private-nix:idmap \
      ${seed} /run/crow-private-nix /run/crow-nix-closure/store-paths

    # No host store, database, profiles, GC roots, or daemon socket is shared
    # with the running guest. Only its private /nix is mounted here.
    exec ${pkgs.systemd}/bin/systemd-nspawn \
      --keep-unit --settings=no --machine=crow-ai --directory="$root" \
      --notify-ready=yes --kill-signal=SIGRTMIN+3 \
      ${lib.escapeShellArgs userNamespaceFlags} \
      --private-network --network-veth \
      --bind=${privateNix}:/nix:idmap \
      --bind-ro=${closure}:/run/crow-nix-closure:idmap \
      ${lib.escapeShellArgs bindFlags} \
      ${lib.escapeShellArgs cfg.extraFlags} \
      ${guestEntry}
  '';
in
{
  containers.crow-ai.privateUsers = uidBase;
  containers.crow-ai.timeoutStartSec = "30min";
  containers.crow-ai.config = {
    nix.enable = true;
    nix.daemon.enable = true;
    users.users.cody-ai = {
      autoSubUidGidRange = lib.mkForce false;
      subUidRanges = [{ startUid = 100000; count = 65536; }];
      subGidRanges = [{ startGid = 100000; count = 65536; }];
    };
  };
  systemd.services."container@crow-ai" = {
    # Replace the upstream launcher, which unconditionally mounts host Nix.
    serviceConfig.ExecStart = lib.mkForce "${run}";
    reloadIfChanged = lib.mkForce false;
    serviceConfig.ExecReload = lib.mkForce [ ];
    unitConfig.RequiresMountsFor = [ privateNix ];
    preStart = lib.mkAfter ''
      ${pkgs.coreutils}/bin/install -d -m 0755 ${privateNix}
    '';
  };
}
