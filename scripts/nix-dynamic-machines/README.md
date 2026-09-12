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
  --state /var/run/nix-builder-registry/probe-state.json \
  --timeout 3 \
  --parallelism 8
```

Then point Lix at the generated file:

```text
builders = @/var/run/nix-builder-registry/machines
```

Due probes run concurrently as `nix store ping --store URI`. SSH key and public-host
key fields from each machine specification are attached to the probe store URI,
so the check uses the same credentials as a real remote build. Failed and timed
out probes are omitted; malformed candidate input fails without changing the
existing output file. Only SSH builders are accepted; includes and semicolon
lists are rejected. Job counts, speed factors, and base64 host-key syntax are
validated before probing. A local error starting or waiting for a probe aborts
the pass and preserves the previous list, while a nonzero probe exit or timeout
marks that candidate unavailable. Timeout cleanup sends SIGKILL to the entire
probe process group after a short SIGTERM grace period.

## Reduced polling

Probe results persist across invocations in `OUTPUT.state.json` by default (or
the path specified by `--state`). The defaults are:

- Healthy builders: recheck after 60 seconds (`--healthy-interval`).
- Unavailable builders: retry after 15, 30, 60, then at most 120 seconds
  (`--retry-interval` and `--max-retry-interval`). A successful probe resets backoff.
- `always` builders: include immediately and never probe, even with `--force`.

Run the utility periodically, for example every 15 seconds. A pass only probes
entries whose deadlines have expired; other entries reuse their previous result.
This is still a one-shot command, not a scheduler. Detection happens at the first
invocation after a deadline, so a slower timer also delays removal and recovery.
The output file and state file are rewritten only when their contents change.

Use `--force` to refresh all `probe` entries immediately after a network change,
wake from sleep, or replacing credentials in place. This flag can be called from
an external event hook; no OS event listeners are installed by the utility.
Edited or new machine lines automatically require a fresh probe. Removed entries
are removed from the output and cache. Changing `--nix` invalidates cached results.
Updated interval flags apply to existing observations, and clock rollback expires
affected observations. SSH configuration or credential contents changing at the
same path require `--force` to bypass an existing deadline.

Overlapping runs for the same output hold an exclusive file lock across cache
loading, probing, and publication, so the second pass can reuse the first pass's
results. Give each output its own state file and retain the `.lock` file while
the service is in use. Candidate, output, and state paths must be distinct. State
should live in a directory writable only by the account running reconciliation.
Missing state triggers fresh probes; malformed or unreadable state aborts without
changing the machines file. Remove a corrupt cache to rebuild it on the next run.

Child process waits use SIGCHLD notifications through `wait-timeout` on Unix,
replacing the former 20 ms `try_wait()` loop. The same concurrent-probe bound and
process-group timeout cleanup still apply. The crate owns a SIGCHLD handler; do
not add another child-signal handler without checking compatibility.
