{ bubblewrap }:

# Codex's proc-mount fallback matches "Can't mount proc" and "/newroot/proc".
# Bubblewrap 0.12 reports the logical destination (/proc) instead, so Codex
# fails under systemd/nspawn's protected proc mounts rather than using its
# existing fallback. Preserve the recognized diagnostic, not a mount-policy
# change. Remove this once the self-managed Codex accepts the new diagnostic.
# See codex-rs/linux-sandbox/src/linux_run_main.rs:is_proc_mount_failure.
bubblewrap.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    substituteInPlace bubblewrap.c \
      --replace-fail 'die_with_mount_error ("Can'"'"'t mount proc on %s", op->dest);' \
        'die_with_mount_error ("Can'"'"'t mount proc on /newroot%s", op->dest);'
  '';
})
