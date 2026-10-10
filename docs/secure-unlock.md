# Secure Boot, remote recovery and TPM disk unlock

Import the flake's `nixosModules.secure-unlock` (includes Lanzaboote), or import
`nixos-modules/secure-unlock` alongside your existing Lanzaboote module.
Enable `boot.secureUnlock` on a UEFI system with a TPM and an existing LUKS root:

```nix
{
  imports = [ inputs.nixos-config.nixosModules.secure-unlock ];

  boot.initrd.luks.devices.system-root.device = "/dev/disk/by-uuid/YOUR-LUKS-UUID";
  boot.secureUnlock = {
    enable = true;
    mapperName = "system-root";
    stateDirectory = "/var/lib/secure-unlock";
    rootVolumeKeyId = import ./volume-identity.nix;
    remoteUnlock = {
      enable = true;
      authorizedKeys = [ "ssh-ed25519 YOUR-PUBLIC-KEY" ];
      port = 2222;
      # Optional; provide the driver/firmware and credentials separately.
      # wifi = { enable = true; interface = "wlp2s0"; };
    };
    tpmUnlock.enable = true;
  };

  boot.initrd.systemd.network.networks."10-wired" = {
    matchConfig.Name = "enp1s0";
    networkConfig.DHCP = "ipv4";
  };
}
```

The host supplies disk layout, filesystem mounts, network interfaces and drivers.
The state directory must persist on the configured encrypted root mapping, and
must exist before provisioning. It is created at boot by tmpfiles. With an
ephemeral root, use a persistent directory such as `/persist` and ensure its
filesystem is mounted for boot. The helper verifies the directory's backing
mapping before touching credentials or enrolling a disk. A ZFS state dataset is
supported when its pool has exactly one disk vdev whose complete backing-device
ancestry passes through the pinned LUKS mapping (including LVM inside LUKS).
Pools with additional vdevs are rejected.

The module enables systemd initrd and Lanzaboote, disables the boot editor,
and pins the root volume before mounting it. Initrd networking and SSH start
only when systemd asks for a passphrase and the configured mapper is still
closed. The default wpa_supplicant Wi-Fi backend also runs after boot using
the sealed credential. Configure wired networking for the running system separately.

For iwd recovery, set `remoteUnlock.wifi.backend = "iwd"` and
`remoteUnlock.wifi.iwdProfileName` to the iwd network filename (for example,
`billy.psk`). Store a complete iwd profile, rather than wpa_supplicant syntax,
at `stateDirectory/credstore/wifi`. The initrd decrypts the TPM-sealed profile
into a private runtime directory and uses networkd for DHCP. Configure stage-2
iwd separately; [Crow](../hosts/crow/README.md#wi-fi-and-sops) uses SOPS for that
profile and preserves the interface name across both boot stages. SOPS secrets
on an encrypted root cannot supply pre-unlock Wi-Fi directly.

## Staged provisioning with one configuration

Ward, Crow and Warbler each use their normal host output throughout installation
and operation (`.#ward`, `.#crow`, `.#warbler`). There are no `*-bootstrap` outputs
or unlock feature toggles to change between stages.

1. **Install and unlock at the console.** Create signing keys before installing
   boot files. With Secure Boot disabled, in Setup Mode, or when running from
   the installer, the bootloader hook stages an empty credential directory and
   skips TPM policy creation. It still signs boot files with Lanzaboote.
   For a freshly formatted disk, set `volume-identity.nix` to `null` in the
   installation checkout first; never reuse the old volume's pin. Record the
   new public ID from `sudo sys root-volume-key-id`, then rebuild the same host.
   An unpinned generation cannot start remote recovery or attempt TPM
   unlock. Keep an existing valid pin when repairing an existing installation.
2. **Enroll Secure Boot with local console access.** Back up firmware databases
   and signing keys, follow the host's firmware procedure, and boot with Secure
   Boot enabled and Setup Mode disabled. Signing keys default to
   `stateDirectory/sbctl`; the host may override that path. Firmware enrollment
   and reboot remain attended operations.
3. **Let the installed host provision SSH.** On a pinned Secure Boot boot,
   `secure-unlock-credentials.service` generates a dedicated initrd SSH host key
   once, preserves it on encrypted storage, and seals it to PCR 7. No manual
   `ssh-keygen` is needed. This identity is separate from normal SSH because its
   sealed copy is used before root is unlocked. To import an existing identity,
   place a root-owned mode-0600 key at `stateDirectory/credstore/ssh-host-key`
   before first provisioning. Wi-Fi and Tailscale are provisioned separately;
   missing initial optional credentials do not block wired SSH.
4. **Rebuild the same host's boot files.** For example,
   `sudo nixos-rebuild boot --flake .#ward`. The hook repeats provisioning
   idempotently, publishes sealed EFI companion credentials, signs the UKIs and updates the
   measured-boot policy. Starting the service alone does not update boot files.
   Verify `stateDirectory/credstore.encrypted/ssh-host-key.pub` through a trusted
   channel, reboot, and test `ssh -t -p 2222 root@HOST` when a passphrase is
   requested. It opens the disk passphrase agent.
5. **Explicitly enroll TPM disk unlock.** Retire unpinned installation entries
   and their accepted measured-boot components using Lanzaboote's policy
   workflow. Boot the current pinned generation, then run
   `sudo sys setup-luks-tpm-unlock`. It verifies a token-free recovery passphrase
   slot before adding the pcrlock token. Test automatic unlock with console
   access available and retain the recovery passphrase. Enabling the option
   prepares PCRs 0, 4 and 7; neither a rebuild nor the boot service enrolls LUKS.

Provisioning records the pinned identity and credentials in
`stateDirectory/provisioning-ready`. Existing sealed deployments are adopted
without rotating their identities. After provisioning, disabled Secure Boot,
a different volume pin, or missing previously provisioned credentials stops
boot-file installation. Restore backups or deliberately migrate the state;
do not delete this record to bypass a failure. A missing ciphertext can be
resealed from its retained plaintext; loss of both copies is an error.

`stateDirectory/initrd-credentials` contains only the selected ciphertext for
boot installation. The hook copies it to the ESP's `loader/credentials/*.cred`;
Lanzaboote loads those files into the initrd at boot. This supported
[systemd credential mechanism](https://systemd.io/CREDENTIALS/) avoids cached
UKIs overlooking later credential updates when rebuilding the same generation.
Ciphertext is authenticated by the TPM credential policy; no plaintext enters
the ESP or Nix store. The PCR policy includes both persistent UKI measurements
and the firmware measurements generated under `/var/lib/pcrlock.d`.
Authoritative inputs stay in `stateDirectory/credstore` on
encrypted storage, sealed copies in `credstore.encrypted`. Optional Wi-Fi starts
once its root-owned mode-0600 profile exists at `credstore/wifi`; Tailscale starts
once its separate identity has been enrolled. Rebuild after either change.
`sudo sys setup-unlock-credentials --ssh-only` can manually reseal SSH; the
normal boot service and install hook handle available credentials automatically.

Warbler's [installation guide](../hosts/warbler/README.md) covers firmware and
policy cleanup. Disk layout, root reset, account setup and firmware backup remain
host-specific. No host is rebooted or enrolled automatically.

## Separate Tailscale identity in the initrd

Set `boot.secureUnlock.remoteUnlock.tailscale.enable = true`. The default node
name is `<hostname>-unlock`; `tailscale.hostName` overrides it. Warbler enables
this as `warbler-unlock`. This does not change `services.tailscale` or its state.

Tailscale starts only when passphrase recovery starts, alongside SSH and DNS.
It uses a dedicated socket, TUN interface and state directory in root-only RAM.
The existing OpenSSH server still handles authentication on the configured
recovery port (2222 on Warbler); Tailscale SSH is disabled. Configure tailnet
grants/ACLs to allow only your recovery clients to reach that node's recovery
port. The existing wired SSH recovery path remains available.

Provision this optional identity after Secure Boot is ready, then rebuild to include it:

1. Build the new system without activation and copy its closure to the host.
   Run the helper from that new closure so it uses the new configuration:

   ```sh
   sudo /nix/store/NEW-SYSTEM/sw/bin/sys setup-unlock-tailscale
   ```

2. Complete the printed Tailscale login URL, registering the dedicated
   `<hostname>-unlock` node. This is a normal, non-ephemeral registration.
   In the Tailscale admin console, disable **key expiry** for that node.
   If the helper reports expiry is still enabled, disable it and rerun the
   same command. Its private provisioning state is retained for retries.
3. Once the helper succeeds, install the new boot generation with
   `nixos-rebuild boot`, or the remote boot-install workflow, and cold-boot
   with console access available. When a passphrase is requested, test:

   ```sh
   ssh -t -p 2222 root@warbler-unlock
   ```

   Verify the initrd SSH fingerprint through a trusted channel first.
   Use the node's Tailscale IP if MagicDNS is unavailable on your workstation.
   After unlock, reconnect to the main host's separate `warbler` identity.
   A successful TPM disk unlock deliberately skips all recovery networking.

Enrollment runs an isolated userspace daemon, never the normal host daemon.
Its state is kept under `stateDirectory/tailscale-initrd` on encrypted root;
the approved snapshot is `stateDirectory/credstore/tailscale-state`.
The helper validates authentication and disabled expiry, stops that daemon,
then seals the snapshot using `systemd-creds --with-key=tpm2 --tpm2-pcrs=7`.
Only `credstore.encrypted/tailscale-state` is published as an encrypted EFI companion; plaintext
and auth keys must never be placed in the checkout or Nix store.
Native Tailscale state encryption is disabled for these isolated daemons:
the provisioning copy is on encrypted root and the initrd copy is TPM-unsealed
into RAM. This avoids layering a second, different TPM policy over PCR 7.

Each boot restores the same non-expiring identity snapshot into writable RAM.
Runtime changes are discarded at switch-root, where the daemon stops and its
runtime directory is removed. There is no automatic copy back from initrd.
Repeat `enroll-tailscale` and rebuild to refresh the snapshot after deliberate
registration changes. Deleting/revoking the node or changing Secure Boot policy
can prevent recovery through Tailscale; retain local-console recovery and an
encrypted offline backup of the credential sources. PCR 7 binds Secure Boot
policy, not an exact kernel generation.

Validate repeated cold boots from the unchanged snapshot on the real tailnet
before relying on this path. The automated VM test uses a public test snapshot
and a substitute daemon to test TPM credential delivery and service lifecycle;
it does not prove Tailscale coordination, ACLs, or unchanged-snapshot reconnects.

References: [tailscaled flags](https://tailscale.com/docs/reference/tailscaled),
[node key expiry](https://tailscale.com/docs/features/access-control/key-expiry).

## Validation

```sh
python3 scripts/test-secure-unlock-setup.py
nix eval --impure --json --file scripts/test-secure-unlock.nix
nix build .#checks.x86_64-linux.secure-unlock .#checks.x86_64-linux.luks-volume-key-id --no-link
```

The evaluation fixture uses a different hostname, root mapper, state directory,
SSH port and Wi-Fi interface without importing Warbler. Warbler's VM test also
exercises Secure Boot, credential sealing, remote recovery and TPM enrollment.
