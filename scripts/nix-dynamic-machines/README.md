# nix-dynamic-machines

`nix-dynamic-machines` probes candidate remote Nix stores and atomically writes
the healthy candidates in the legacy Nix machines-file format. It is a one-shot
reconciler intended to run periodically as root under systemd or launchd.

Candidate lines are normal Nix machine specifications prefixed with a policy:

```text
# Do not probe stable activation proxies: probing could start their backend.
always ssh-ng://root@docker-linux-builder x86_64-linux /var/lib/docker-linux-builder/id_ed25519 4 20 benchmark,big-parallel

# Probe remote machines using their configured key and public host key.
probe ssh-ng://nix-ssh@mifflin x86_64-linux /run/secrets/mifflin-ssh-key 4 10 kvm,benchmark,big-parallel - BASE64_HOST_KEY
```

Run one reconciliation pass with:

```console
nix-dynamic-machines \
  --candidates /etc/nix/builder-candidates \
  --output /var/run/nix-builder-registry/machines \
  --timeout 3 \
  --parallelism 8
```

Then point Lix at the generated file:

```text
builders = @/var/run/nix-builder-registry/machines
```

Probes run concurrently as `nix store ping --store URI`. SSH key and public-host
key fields from each machine specification are attached to the probe store URI,
so the check uses the same credentials as a real remote build. Failed and timed
out probes are omitted; malformed candidate input fails without changing the
existing output file. Only SSH builders are accepted; includes and semicolon
lists are rejected. Job counts, speed factors, and base64 host-key syntax are
validated before probing. A local error starting or waiting for a probe aborts
the pass and preserves the previous list, while a nonzero probe exit or timeout
marks that candidate unavailable. Timeout cleanup sends SIGKILL to the entire
probe process group after a short SIGTERM grace period.
