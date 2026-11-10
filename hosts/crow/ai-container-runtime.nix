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
  # An empty sysfs instance mounted for a dedicated network namespace, bound
  # read-only into the guest so nested user namespaces can mount sysfs.
  # nspawn presents a user-namespaced container's /sys as a tmpfs with
  # read-only subtree binds, so no sysfs exists at a superblock root and the
  # kernel's mount_too_revealing() check refuses every fresh sysfs mount in
  # any child user namespace ("VFS: Mount too revealing"). Rootless Docker
  # containers fail to start on exactly that: runc mounts a per-network-
  # namespace sysfs read-only with the classic mount(2) call. The seed is an
  # instance created for a throwaway network namespace (it lists only "lo"),
  # so it discloses nothing and, being read-only, satisfies runc's
  # MS_RDONLY request while leaving the guest's own curated /sys untouched.
  sysfsSeed = "/run/crow-ai-sysfs-seed";
  sysfsSeedNetns = "crow-ai-sysfs-seed";
  sysfsSeedGuestPath = "/run/host/sysfs-seed";
  seed = pkgs.writeShellScript "crow-ai-seed-nix" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    ${builtins.readFile ./ai-container-seed-nix.sh}
  '';
  # nspawn overmounts /proc files and directories in every container (masked
  # /proc/kcore, /proc/keys, /proc/kallsyms, ... plus a read-only /proc/sys).
  # Those mounts are unlocked at the container's own privilege level, but the
  # kernel locks them in every child user namespace and then refuses the fresh
  # per-build /proc remounts that Nix's sandbox performs ("VFS: Mount too
  # revealing"; see mount_too_revealing() in fs/namespace.c). Remove them so
  # guest builds keep the unmodified Nix sandbox. This grants nothing: guest
  # root could unmount them at any time, and the uid remap keeps the masked
  # nodes protected by DAC (/proc/kcore is 0400 root:root against guest uid
  # 1048576, and so on).
  unmaskProc = pkgs.writeShellScript "crow-ai-unmask-proc" ''
    set -eu
    # Arguments: [--dry-run] [MOUNTINFO]. --dry-run lists targets instead of
    # unmounting, for scripts/test-crow-unmask-proc.py.
    dry_run=false
    mountinfo=/proc/self/mountinfo
    if [ "''${1-}" = "--dry-run" ]; then
      dry_run=true
      shift
    fi
    if [ "$#" -ge 1 ]; then
      mountinfo=$1
    fi
    removed=0
    left=0
    # Deepest targets first. Deduplicate whole lines before the numeric
    # sort: "sort -rn -u" collapses different paths that share a depth
    # number and would silently leave most overmounts in place.
    for target in $(${pkgs.gawk}/bin/gawk '$5 ~ /^\/proc\// { print gsub(/\//, "/", $5), $5 }' "$mountinfo" \
        | ${pkgs.coreutils}/bin/sort -u \
        | ${pkgs.coreutils}/bin/sort -rn \
        | ${pkgs.coreutils}/bin/cut -d' ' -f2-); do
      if $dry_run; then
        echo "would unmount: $target"
        removed=$((removed + 1))
        continue
      fi
      if ${pkgs.util-linux}/bin/umount "$target" 2>/dev/null \
         || ${pkgs.util-linux}/bin/umount -l "$target" 2>/dev/null; then
        removed=$((removed + 1))
      else
        left=$((left + 1))
        echo "crow-ai-unmask-proc: could not unmount $target" >&2
      fi
    done
    echo "crow-ai-unmask-proc: unmounted $removed mount(s) under /proc, $left remaining"
  '';
  bindFlags = lib.mapAttrsToList
    (name: mount:
      let
        flag = if mount.isReadOnly then "--bind-ro" else "--bind";
        source = if mount.hostPath == null then mount.mountPoint else mount.hostPath;
        # The scratch filesystem and root-only hardware template need their
        # original ownership translated. Device nodes already have mapped
        # UIDs. Staged OpenCode secrets are owned by container-mapped UIDs
        # already, so a plain bind resolves them correctly in the guest.
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
      --bind-ro=${sysfsSeed}:${sysfsSeedGuestPath} \
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
    # Keep Nix's full build sandbox; crow-ai-unmask-proc clears nspawn's
    # /proc overmounts first so the kernel accepts the sandbox's fresh proc
    # mounts. If that ever stops working (a future nspawn/systemd change),
    # fall back to unsandboxed builds with a warning instead of failing:
    # the nspawn boundary still confines the daemon's nixbld builders.
    # mkForce overrides NixOS's deliberate sandbox-fallback = false default.
    nix.settings.sandbox-fallback = lib.mkForce true;
    systemd.services.crow-ai-unmask-proc = {
      description = "Clear nspawn's /proc overmounts for nested Nix sandboxes";
      wantedBy = [ "multi-user.target" ];
      before = [ "nix-daemon.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${unmaskProc}";
      };
    };
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
      # Prepare the empty sysfs seed (see the sysfsSeed comment above).
      # nsenter rather than ip netns exec: the mount must land in this mount
      # namespace, and ip netns exec would unshare a throwaway one. The
      # network namespace and mount persist across container restarts and
      # are recreated after host reboots.
      ${pkgs.iproute2}/bin/ip netns add ${sysfsSeedNetns} 2>/dev/null || true
      ${pkgs.coreutils}/bin/mkdir -p ${sysfsSeed}
      if ! ${pkgs.util-linux}/bin/findmnt -rn -t sysfs -M ${sysfsSeed} >/dev/null; then
        ${pkgs.util-linux}/bin/nsenter --net=/run/netns/${sysfsSeedNetns} \
          ${pkgs.util-linux}/bin/mount -t sysfs sysfs ${sysfsSeed}
      fi
    '';
  };
}
