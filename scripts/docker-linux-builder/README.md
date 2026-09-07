# On-demand Docker Linux builder on u3

The system launchd service `org.nixos.docker-linux-builder` runs a small Python
SSH proxy as `config.system.primaryUser`. Its home paths come from
`config.users.users.${config.system.primaryUser}.home`.
It listens on **127.0.0.1:31023**, starts the pre-provisioned
`nix-linux-builder` container in the **orbstack** Docker context, and forwards
SSH to **127.0.0.1:31024**. Concurrent connections share one container.

After all connections close, the container stops after five minutes (plus up to
30 seconds for the idle check). A remaining `nix-daemon` process prevents the
stop, including after a proxy restart. A silent active connection is not idle.
The stopped container is not repeatedly polled, so the proxy does not keep
waking Docker. OrbStack must be available; the proxy does not launch the
OrbStack app or shut down its shared Linux VM.

`nix-linux-builder-store` persists `/nix`, including the store and its database.
`nix-linux-builder-keys` persists the SSH host key and authorized public key.
The container uses no privileged mode, host store mount, or Docker socket mount.
Nix sandboxing is disabled inside the unprivileged container; use it for trusted
build inputs. The SSH key permits only `nix-daemon --stdio`, with no shell, PTY,
password authentication, or forwarding. This builder advertises x86_64-linux,
benchmark, and big-parallel, but not KVM.

## Provision and activate

From the repository root, with OrbStack running:

```sh
python3 scripts/docker-linux-builder/setup.py
sudo darwin-rebuild switch --flake path:/Volumes/dev/p/nixos-config#u3
nix store ping --store ssh-ng://root@docker-linux-builder
```

Setup creates a dedicated client key and pinned `known_hosts` under
`~/.local/state/nix-docker-builder`. It does not start the builder. The macOS
Nix daemon (root) uses that key through the system SSH configuration.
The path flake syntax includes new files before they have been committed.

The QEMU builder remains installed to preserve its disk, but has RunAtLoad and
KeepAlive disabled and is excluded from Nix's builder list. Its previous
`launchctl disable system/org.nixos.linux-builder` override also remains in place.
The Docker builder is preferred over `mifflin`, which remains a remote fallback.

## Inspect and maintain

```sh
launchctl print system/org.nixos.docker-linux-builder
tail -f ~/Library/Logs/docker-linux-builder.log
docker --context orbstack inspect --format '{{.State.Status}}' nix-linux-builder
```

To update the image, first let all builds finish, stop/remove **only the
container**, and rerun setup. Keep the named volumes to preserve its cache and
host key. Setup refuses to silently replace an existing container whose image
differs. The Alpine base is pinned by digest; APK packages resolve from its
stable release repository when the layer is rebuilt.

To garbage collect the container's store during a maintenance window:

```sh
docker --context orbstack start nix-linux-builder
docker --context orbstack exec nix-linux-builder nix-store --gc
docker --context orbstack stop nix-linux-builder
```

## Validation

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/docker-linux-builder -v
```

For a fast end-to-end idle test, stop the installed proxy service first and run
`python3 scripts/docker-linux-builder/proxy.py --idle-seconds 3` in a terminal.
Submit a real Linux build over `ssh-ng://root@docker-linux-builder`; verify it
finishes before the container exits, and that a second request restarts the
container with its previous output still present. Restore the launchd service
afterward. Do not run two proxies against the same container.
