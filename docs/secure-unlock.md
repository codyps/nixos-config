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
mapping before touching credentials or enrolling a disk.

The module enables systemd initrd and Lanzaboote, disables the boot editor,
and pins the root volume before mounting it. Initrd networking and SSH start
only when systemd asks for a passphrase and the configured mapper is still
closed. Wi-Fi, when enabled, also runs after boot using the sealed credential.
Configure wired networking for the running system separately.

## Installation

1. Install with the module enabled but `remoteUnlock.enable = false` and
   `tpmUnlock.enable = false`. A null `rootVolumeKeyId` is allowed during this
   attended bootstrap only. After formatting, run `sudo root-volume-key-id`
   and save its public output as a quoted Nix string in `volume-identity.nix`.
   The configured helper is installed with the module, including during bootstrap.
2. Back up firmware keys, create signing keys, sign boot files, and enroll Secure
   Boot using the machine's firmware procedure. The default signing-key directory
   is `stateDirectory/sbctl`; override `boot.lanzaboote.pkiBundle` if needed.
   Boot and verify Secure Boot is enabled and Setup Mode is disabled.
3. Enable remote recovery and, if desired, TPM support as above, then rebuild.
   Credential provisioning runs before bootloader installation. It generates the
   dedicated SSH identity once and seals it to PCR 7. To supply your own identity,
   install a root-owned mode-0600 key at `stateDirectory/credstore/ssh-host-key`
   before the first Secure Boot boot. For Wi-Fi, install a complete
   wpa_supplicant configuration at `stateDirectory/credstore/wifi` before rebuilding.
4. Verify the fingerprint of `stateDirectory/credstore.encrypted/ssh-host-key.pub`
   through a trusted channel, then reboot and test `ssh -p 2222 root@HOST`.
   It opens the disk passphrase agent. Keep the recovery passphrase.
5. For optional disk enrollment, first retire any unpinned bootstrap boot entries
   and their measured-boot policy components using Lanzaboote's policy workflow.
   After booting the current pinned, TPM-enabled generation, run
   `sudo secure-unlock-setup enroll-disk`. It verifies a token-free recovery
   passphrase slot before adding a pcrlock TPM token. Reboot with console access
   available to verify automatic unlock and that recovery networking stays idle.

Enabling TPM support prepares the measured-boot policy (PCRs 0, 4 and 7);
it does not enroll the disk. Enrollment remains an explicit command.
Plaintext credential backups stay on encrypted storage; only TPM-sealed
ciphertext enters the initrd. Existing SSH identities are preserved, including
during resealing. `sudo secure-unlock-setup credentials` manually checks/reseals
the configured credentials; rebuild afterward to include changed ciphertext.

Warbler uses this module with its existing `/persist` paths, volume identity,
and DHCP settings. Its [installation guide](../hosts/warbler/README.md) includes
the detailed firmware and bootstrap-policy cleanup procedure. The Warbler
installer, partition layout, root reset, account setup and firmware backup remain
host-specific.

## Validation

```sh
python3 scripts/test-secure-unlock-setup.py
nix eval --impure --json --file scripts/test-secure-unlock.nix
nix build .#checks.x86_64-linux.secure-unlock .#checks.x86_64-linux.luks-volume-key-id --no-link
```

The evaluation fixture uses a different hostname, root mapper, state directory,
SSH port and Wi-Fi interface without importing Warbler. Warbler's VM test also
exercises Secure Boot, credential sealing, remote recovery and TPM enrollment.
