# nix-dynamic-machines

`nix-dynamic-machines` probes candidate remote Nix stores and atomically writes
the healthy candidates in the legacy Nix machines-file format. Run it once, or
use `--watch` as a long-running service with internal scheduling.

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

Without `--watch`, run the utility periodically. A pass only probes
entries whose deadlines have expired; other entries reuse their previous result.
In one-shot mode detection happens at the first
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

Instances hold an exclusive file lock across cache loading, probing, and
publication (for the entire lifetime in watch mode). A second instance fails
promptly instead of waiting behind a watcher; send SIGHUP to refresh the running
watcher. Give each output its own state file and retain the `.lock` file while
the service is in use. Candidate, output, and state paths must be distinct. State
should live in a directory writable only by the account running reconciliation.
Missing state triggers fresh probes; malformed or unreadable state aborts without
changing the machines file. Remove a corrupt cache to rebuild it on the next run.

## Internal scheduler

Add `--watch` to the command above to use a single-thread Tokio runtime. Both
modes use async subprocess waits and timeout futures, with no child-status
polling loop. The watcher sleeps until the earliest builder deadline; it has no
fixed scan interval and no timer wakeups when there are only `always` entries.
The existing healthy interval and capped failure backoff still apply.

At most `--parallelism` probes run at once, and a builder cannot have overlapping
probes. Results publish as each probe completes, without waiting for slower
builders. Each next deadline is measured from that probe's completion. Filesystem
publication runs off the event-loop thread, with one ordered writer. Runtime
deadlines use a monotonic clock; persisted observations use wall-clock timestamps
to reconstruct remaining delays after a restart.

- SIGHUP rereads candidates and forces all `probe` entries due. Invalid input
  keeps the current configuration running. A valid reload cancels and reaps old
  probes before scheduling the new configuration; old results cannot re-add a
  removed builder. `always` entries are never probed.
- SIGTERM or SIGINT stops scheduling, cancels in-flight probes, flushes accepted
  state, and releases the lock. Timeout and cancellation send SIGTERM to each
  probe process group, then SIGKILL after 200 ms, and reap the direct child.
- A local launch/wait error preserves that builder's cached membership and
  retries after `--retry-interval`; it is not an offline observation. Publication
  errors stop the watcher after probe cleanup, allowing the supervisor to restart
  it. A missing observation is not treated as healthy.

Use SIGHUP from network-change or wake hooks as needed. Candidate files and network
events are not watched automatically, and monotonic-clock suspend behavior varies
by platform. Moving timers inside the process does not eliminate the network
probes needed to detect an unresponsive remote host.

For systemd, replace the periodic timer/oneshot unit with a `Type=simple` service
whose `ExecStart` is the command above plus `--watch`, with `Restart=on-failure`
and `ExecReload=/bin/kill -HUP $MAINPID` (use the packaged kill path on NixOS).
For launchd, use the same arguments with `RunAtLoad` and `KeepAlive`, removing
`StartInterval`. Keep the runtime directory writable only by the service account;
allow several seconds for graceful shutdown. No host service is installed by this
package alone. Do not run the old timer alongside the watcher.

## NixOS and nix-darwin modules

The flake exports `nixosModules.nix-dynamic-machines` and
`darwinModules.nix-dynamic-machines`. Import the appropriate module and configure:

```nix
{
  services.nix-dynamic-machines = {
    enable = true;
    alwaysBuilders = [
      "ssh-ng://root@docker-linux-builder x86_64-linux - 4 20"
    ];
    probeBuilders = [
      "ssh-ng://nix@remote x86_64-linux /run/secrets/builder-key 8 10"
    ];
    timeout = 3;
    parallelism = 8;
    healthyInterval = 60;
    retryInterval = 15;
    maxRetryInterval = 120;
  };
}
```

Within this repository, import `nixos-modules/nix-dynamic-machines.nix` or
`nix-darwin/modules/nix-dynamic-machines.nix`. The modules package the utility
without requiring an overlay; `package` can override it. No hosts enable it by
default. Candidate syntax is validated by the utility during the configuration
build, with every entry temporarily classified as `always`: validation never
contacts a remote machine or starts an on-demand builder.

Both services run as root using `nix.package` and an explicit SSH executable
search path. They enable distributed builds and `nix-command`, and configure
`nix.settings.builders` to read the runtime machines file. Existing
`nix.buildMachines` remain available through `/etc/nix/machines` **without probes**;
move any machines that should be filtered from that list into `probeBuilders`.
Do not separately override `nix.settings.builders` when using the module.

State lives in `/var/lib/nix-dynamic-machines` on NixOS or
`/var/db/nix-dynamic-machines` on Darwin. Activation creates the root-owned
directory and seeds a missing machines file with `alwaysBuilders`; it does not
probe or overwrite an existing runtime list. Service startup also initializes
the directory, then runs `--watch`. Configuration changes alter the service
wrapper so normal system activation restarts it with the new candidates.
State persists across restarts. Removing/disabling the module does not delete it.

NixOS uses `nix-dynamic-machines.service` with restart-on-failure and journal logs.
Refresh using `sudo systemctl reload nix-dynamic-machines`. Darwin uses launchd
label `org.nixos.nix-dynamic-machines`, KeepAlive, and
`/var/log/nix-dynamic-machines.log`. Refresh with
`sudo launchctl kill SIGHUP system/org.nixos.nix-dynamic-machines`.
Network/wake hooks can call these commands; there are no external polling timers.

Candidate strings are public store data. Specify private keys by runtime path,
and configure pinned public host keys or root's SSH known-hosts configuration.
Avoid putting on-demand builders in `probeBuilders`, including alongside an
unconditional copy. Initial activation changes Nix daemon configuration; this is
separate from subsequent machines-file updates by the running watcher.

Evaluate module regression tests (NixOS, Intel Darwin, and ARM Darwin) with:

```console
nix eval --impure --json --option eval-cache false --file scripts/test-nix-dynamic-machines-modules.nix
```
