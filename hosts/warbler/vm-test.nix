{ pkgs, self, disko, impermanence, lanzaboote, sops-nix }:
let
  inherit (pkgs) lib;
  # Public upstream test fixtures, never production identities or signing keys.
  keys = lanzaboote + "/nix/tests/fixtures/uefi-keys";
  # Deterministic public test key only; never use this for real installations.
  volumeKey = pkgs.writeText "warbler-test-volume-key" "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
  volumeUuid = "11111111-2222-3333-4444-555555555555";
  sshKey = pkgs.path + "/nixos/tests/initrd-network-ssh/id_ed25519";
  # Public test identity and deliberately non-secret test data only.
  testSecrets = pkgs.runCommand "warbler-test-secrets.json"
    { nativeBuildInputs = [ pkgs.sops pkgs.ssh-to-age ]; }
    ''
      recipient=$(ssh-to-age -i ${sshKey + ".pub"})
      printf '{"probe":"warbler-sops-test"}' | \
        sops --encrypt --age "$recipient" --input-type json --output-type json /dev/stdin > "$out"
    '';
  authVariables = pkgs.runCommand "warbler-test-efi-auth"
    {
      nativeBuildInputs = [ pkgs.sbctl ];
    } ''
    mkdir -p $out
    cd $out
    sbctl --config ${pkgs.writeText "test-sbctl.conf" ''
      keydir: ${keys}/keys
      guid: ${keys}/GUID
    ''} enroll-keys --export auth --yes-this-might-brick-my-machine
  '';
in
pkgs.testers.runNixOSTest {
  name = "warbler-vm";
  # These are scheduler tags, not capabilities needed by TCG. The store-only
  # Docker builder does not advertise either; no shell access is necessary.
  requiredFeatures = { kvm = false; nixos-test = false; };
  globalTimeout = 3600;
  node.specialArgs = { inherit self; };
  defaults = {
    # Load the emulated hardware drivers before waiting for initrd mounts.
    boot.initrd.kernelModules = [ "virtio_pci" "virtio_blk" "virtio_net" "virtiofs" ];
  };

  nodes = {
    installer = { ... }: {
      imports = [ disko.nixosModules.disko ./disko.nix ];
      disko.enableConfig = false;
      disko.devices.disk.system.device = lib.mkForce "/dev/vdb";
      disko.devices.disk.system.content.partitions.crypt.content.extraFormatArgs = [
        "--volume-key-file"
        "${volumeKey}"
        "--uuid"
        volumeUuid
      ];
      virtualisation.emptyDiskImages = [ 8192 ];
      virtualisation.memorySize = 1536;
      environment.systemPackages = [ pkgs.cryptsetup pkgs.nixos-install-tools ];
    };
    client = { ... }: {
      virtualisation.memorySize = 512;
      environment.systemPackages = [ pkgs.openssh pkgs.netcat-openbsd (pkgs.python3.withPackages (p: [ p.pexpect ])) ];
      environment.etc."test-ssh-key" = { source = sshKey; mode = "0600"; };
    };
    warbler = { config, ... }: {
      disabledModules = [ ./hardware-configuration.nix ];
      imports = [
        disko.nixosModules.disko
        impermanence.nixosModules.impermanence
        lanzaboote.nixosModules.lanzaboote
        sops-nix.nixosModules.sops
        ../../nixos/common.nix
        ./configuration.nix
      ];
      disko.devices.disk.system.device = lib.mkForce "/dev/vda";
      sops.secrets.vm-probe = {
        sopsFile = "${testSecrets}";
        format = "json";
        key = "probe";
        neededForUsers = true;
      };
      fileSystems."/nix/.ro-store" = {
        device = "nix-store";
        # Match the current NixOS VM runner's virtiofs store export.
        fsType = "virtiofs";
        neededForBoot = true;
        options = [ "ro" ];
      };
      fileSystems."/nix/store" = {
        neededForBoot = true;
        overlay = {
          lowerdir = [ "/nix/.ro-store" ];
          upperdir = "/nix/.rw-store/upper";
          workdir = "/nix/.rw-store/work";
        };
      };
      documentation.enable = false;
      hardware.enableRedistributableFirmware = lib.mkForce false;
      # Keep filesystem/crypto modules supplied by NixOS; only the physical
      # hardware module above is disabled, not the drivers required by LUKS.
      boot.initrd.kernelModules = [ "tpm_tis" ];
      services.tailscale.enable = lib.mkForce false;
      nix.gc.automatic = lib.mkForce false;
      nix.optimise.automatic = lib.mkForce false;
      # Override the production setting, while allowing the remote
      # specialisation's mkForce to enable recovery on subsequent boots.
      boot.secureUnlock.remoteUnlock.enable = lib.mkOverride 60 false;
      boot.secureUnlock.tpmUnlock.enable = lib.mkOverride 60 false;
      boot.secureUnlock.remoteUnlock.wifi.enable = true;
      boot.secureUnlock.rootVolumeKeyId = lib.mkForce "77e740d9d987a52981ee75ae6ab327c2b70a8b49c6e36258abc426db85c5f831";
      boot.lanzaboote.settings.secure-boot-enroll = "force";
      boot.loader.timeout = 1;
      boot.initrd.network.ssh.authorizedKeys = lib.mkForce [ (builtins.readFile (sshKey + ".pub")) ];
      boot.initrd.systemd.network.networks."10-wired" = {
        matchConfig.Name = lib.mkForce "eth1";
        networkConfig.DHCP = lib.mkForce "no";
        address = [ "192.168.1.3/24" ];
      };
      # Test network addressing must agree in both boot stages.
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [{ address = "192.168.1.3"; prefixLength = 24; }];
      boot.initrd.systemd.services.secure-unlock-wifi.enable = lib.mkForce false;
      systemd.services.secure-unlock-wifi.enable = lib.mkForce false;

      specialisation.remote.configuration = {
        boot.secureUnlock.remoteUnlock.enable = lib.mkForce true;
        boot.secureUnlock.tpmUnlock.enable = lib.mkForce true;
        # /run survives switch-root, recording even briefly started services.
        boot.initrd.systemd.services.systemd-networkd.serviceConfig.ExecStartPre =
          "+${pkgs.coreutils}/bin/touch /run/warbler-initrd-networkd-started";
        boot.initrd.systemd.services.sshd.serviceConfig.ExecStartPre =
          "+${pkgs.coreutils}/bin/touch /run/warbler-initrd-sshd-started";
      };

      virtualisation = {
        memorySize = 3072;
        useBootLoader = true;
        directBoot.enable = false;
        useEFIBoot = true;
        efi.keepVariables = false;
        tpm.enable = true;
        useDefaultFilesystems = false;
        fileSystems = lib.mkForce { };
        # Same optimisation as disko's own installer tests: /nix state remains
        # encrypted, but immutable store objects are supplied over read-only virtiofs.
        # A small encrypted upper layer permits Nix's generation bookkeeping.
        mountHostNixStore = true;
        writableStore = false;
        bootPartition = null;
      };
      environment.systemPackages = [ (pkgs.python3.withPackages (p: [ p.pexpect ])) pkgs.jq ];
      system.build.testClosure = pkgs.closureInfo { rootPaths = [ config.system.build.toplevel ]; };
    };
  };

  testScript = { nodes, ... }: ''
    import os
    import shlex
    from datetime import timedelta
    from pathlib import Path

    password = "warbler-test-passphrase"
    disk = "/dev/disk/by-partlabel/disk-system-crypt"
    installer.start()
    client.start()
    # The driver's initial shell connection has a hard-coded five-minute
    # timeout. TCG cold boots can exceed that; wait for its console marker first.
    installer.wait_for_console_text("connecting to host", timeout=timedelta(minutes=15))
    client.wait_for_console_text("connecting to host", timeout=timedelta(minutes=15))
    installer.wait_for_unit("multi-user.target")
    client.wait_for_unit("multi-user.target")

    with subtest("install actual disko layout on a disposable disk"):
        installer.succeed("udevadm settle --timeout=300")
        installer.succeed(f"printf %s {password} > /tmp/warbler-luks-password")
        installer.succeed("${nodes.installer.system.build.diskoScript}")
        installer.succeed("mkdir -p /mnt/nix/store /mnt/etc /mnt/persist/var/lib/sbctl /mnt/persist/credstore.encrypted")
        installer.succeed("install -d -m 700 /mnt/persist/ssh; install -m 600 ${sshKey} /mnt/persist/ssh/ssh_host_ed25519_key")
        installer.succeed("mount --bind /nix/store /mnt/nix/store")
        installer.succeed("cp -r ${keys}/. /mnt/persist/var/lib/sbctl/; chmod -R u+w /mnt/persist/var/lib/sbctl")
        # The not-yet-selected remote specialisation needs placeholder blobs
        # for initial signing. They cannot decrypt and contain no real secrets.
        installer.succeed("echo unprovisioned > /mnt/persist/credstore.encrypted/wifi; echo unprovisioned > /mnt/persist/credstore.encrypted/ssh-host-key")
        installer.succeed("touch /mnt/etc/NIXOS; mkdir -p /mnt/nix/var/nix/profiles")
        installer.succeed("nixos-enter --root /mnt --system ${nodes.warbler.system.build.toplevel} -- nix-store --load-db < ${nodes.warbler.system.build.testClosure}/registration")
        installer.succeed("nixos-enter --root /mnt --system ${nodes.warbler.system.build.toplevel} -- nix-env -p /nix/var/nix/profiles/system --set ${nodes.warbler.system.build.toplevel}")
        installer.succeed("install -d -m 700 /run/account-passwords; umask 077; printf %s Abcdef-ghijkl-mnopq7-RS > /run/account-passwords/root; printf %s Tuvwxy-zabcde-fghij8-KL > /run/account-passwords/cody")
        installer.succeed("${nodes.warbler.system.build.toplevel}/sw/bin/warbler-account-passwords initialize --root /mnt --password-dir /run/account-passwords")
        installer.succeed("NIXOS_INSTALL_BOOTLOADER=1 nixos-enter --root /mnt -- ${nodes.warbler.system.build.toplevel}/bin/switch-to-configuration boot")
        installer.succeed("rm /mnt/persist/credstore.encrypted/wifi /mnt/persist/credstore.encrypted/ssh-host-key")
        installer.succeed("mkdir -p /mnt/boot/loader/keys/auto; cp ${authVariables}/*.auth /mnt/boot/loader/keys/auto/; sync")
        installer.shutdown()

    os.environ["NIX_DISK_IMAGE"] = str(Path(installer.state_dir) / "empty0.qcow2")
    warbler.start(allow_reboot=True)

    def console_unlock():
        warbler.wait_for_console_text("Please enter passphrase")
        warbler.send_console(password + "\n")
        warbler.wait_for_unit("multi-user.target")

    with subtest("UEFI Secure Boot and manual recovery unlock"):
        console_unlock()
        warbler.succeed("bootctl status | grep 'Secure Boot: enabled'")
        warbler.succeed("test $(cat ${nodes.warbler.sops.secrets.vm-probe.path}) = warbler-sops-test")
        ssh_identity = warbler.succeed("ssh-keygen -y -f /persist/ssh/ssh_host_ed25519_key")
        for mount, subvol in [("/", "root"), ("/nix", "nix"), ("/home", "home"), ("/persist", "persist")]:
            warbler.succeed(f"test $(findmnt -n -o FSTYPE --mountpoint {mount}) = btrfs && test $(findmnt -n -o FSROOT --mountpoint {mount}) = /{subvol}")

    with subtest("volume pin rejects a substituted key or UUID"):
        warbler.succeed("PATH=${lib.makeBinPath [ pkgs.python3 pkgs.cryptsetup pkgs.systemd pkgs.coreutils pkgs.util-linux ]}:$PATH bash ${../../scripts/test-warbler-volume-key.sh}")

    with subtest("provision real TPM credentials and preserve SSH identity on rerun"):
        warbler.succeed("install -d -m 700 /persist/credstore")
        warbler.succeed("umask 077; printf 'network={\n ssid=\"test\"\n psk=\"test-password\"\n}\n' > /persist/credstore/wifi")
        warbler.succeed("systemctl start secure-unlock-credentials.service")
        warbler.wait_until_succeeds("test -s /persist/credstore.encrypted/ssh-host-key", timeout=120)
        warbler.succeed("test -s /persist/credstore.encrypted/ssh-host-key; test -s /persist/credstore.encrypted/wifi; test -s /persist/credstore/ssh-host-key")
        automatic_identity = warbler.succeed("cat /persist/credstore.encrypted/ssh-host-key.pub")
        automatic_blob = warbler.succeed("sha256sum /persist/credstore.encrypted/ssh-host-key")
        warbler.succeed("systemctl start secure-unlock-credentials.service")
        assert automatic_blob == warbler.succeed("sha256sum /persist/credstore.encrypted/ssh-host-key")
        warbler.succeed("umask 077; printf 'network={\n ssid=\"test\"\n psk=\"test-password\"\n}\n' > /run/wifi.conf")
        warbler.succeed("secure-unlock-setup credentials --wifi-file /run/wifi.conf")
        identity = warbler.succeed("cat /persist/credstore.encrypted/ssh-host-key.pub")
        assert identity == automatic_identity
        warbler.succeed("secure-unlock-setup credentials")
        assert identity == warbler.succeed("cat /persist/credstore.encrypted/ssh-host-key.pub")
        warbler.succeed("systemd-run --wait --pipe -p LoadCredentialEncrypted=wifi:/persist/credstore.encrypted/wifi sh -c '${pkgs.diffutils}/bin/cmp \"$CREDENTIALS_DIRECTORY/wifi\" /run/wifi.conf'")
        client.succeed("printf %s " + shlex.quote("[192.168.1.3]:2222 " + identity) + " > /etc/test-known-hosts")

    with subtest("boot signed remote-unlock generation"):
        # Pass the actual store root, not a path inside the parent generation:
        # nix-env otherwise canonicalises it back to the parent's store root.
        remote = "${nodes.warbler.specialisation.remote.configuration.system.build.toplevel}"
        warbler.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {remote}")
        warbler.succeed(f"test $(readlink -f /nix/var/nix/profiles/system) = {remote}")
        warbler.succeed(f"{remote}/bin/switch-to-configuration boot")
        warbler.shutdown()
        warbler.start()
        client.wait_until_succeeds("nc -z 192.168.1.3 2222")
        # A real SSH PTY exercises the restricted ask-password-agent shell.
        ssh = "ssh -tt -i /etc/test-ssh-key -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/test-known-hosts -p 2222 root@192.168.1.3"
        script = f"import pexpect; p=pexpect.spawn({ssh!r}, encoding='utf-8', timeout=120); p.expect('passphrase'); p.sendline({password!r}); p.expect(pexpect.EOF)"
        client.succeed("python3 -c " + shlex.quote(script))
        warbler.wait_for_unit("multi-user.target")
        warbler.succeed("test -e /run/warbler-initrd-networkd-started && test -e /run/warbler-initrd-sshd-started")

    with subtest("enroll TPM with a verified recovery passphrase"):
        warbler.wait_for_unit("systemd-pcrlock-make-policy.service")
        script = f"import pexpect; p=pexpect.spawn('secure-unlock-setup enroll-disk', encoding='utf-8', timeout=120); p.expect('passphrase:'); p.sendline({password!r}); p.expect('TPM enrolled'); p.expect(pexpect.EOF); p.close(); assert p.exitstatus == 0"
        warbler.succeed("python3 -c " + shlex.quote(script))
        warbler.succeed("secure-unlock-setup enroll-disk")
        warbler.succeed("touch /ephemeral-marker /persist/persistent-marker /home/home-marker /nix/nix-marker")
        warbler.succeed("btrfs subvolume create /ephemeral-subvol; btrfs subvolume create /ephemeral-subvol/nested; touch /ephemeral-subvol/nested/marker")
        root_id = warbler.succeed("btrfs inspect-internal rootid /")
        machine_id = warbler.succeed("cat /etc/machine-id")
        warbler.shutdown()
        warbler.start()
        warbler.wait_for_unit("multi-user.target")
        warbler.succeed("test ! -e /run/warbler-initrd-networkd-started && test ! -e /run/warbler-initrd-sshd-started")
        warbler.succeed("test ! -e /ephemeral-marker && test ! -e /ephemeral-subvol && test -e /persist/persistent-marker && test -e /home/home-marker && test -e /nix/nix-marker")
        assert root_id != warbler.succeed("btrfs inspect-internal rootid /")
        warbler.succeed("test $(cat ${nodes.warbler.sops.secrets.vm-probe.path}) = warbler-sops-test")
        assert ssh_identity == warbler.succeed("ssh-keygen -y -f /persist/ssh/ssh_host_ed25519_key")
        assert machine_id == warbler.succeed("cat /etc/machine-id")

    with subtest("sealed credentials reject a changed PCR 7"):
        blobs = warbler.succeed("sha256sum /persist/credstore.encrypted/wifi /persist/credstore.encrypted/ssh-host-key")
        warbler.succeed("tpm2_pcrextend 7:sha256=" + "01" * 32)
        warbler.fail("systemd-creds decrypt --name=ssh-host-key /persist/credstore.encrypted/ssh-host-key /run/rejected-key")
        assert blobs == warbler.succeed("sha256sum /persist/credstore.encrypted/wifi /persist/credstore.encrypted/ssh-host-key")
        warbler.succeed("systemctl start secure-unlock-credentials.service")
        assert identity == warbler.succeed("cat /persist/credstore.encrypted/ssh-host-key.pub")
        warbler.succeed("systemd-creds decrypt --name=ssh-host-key /persist/credstore.encrypted/ssh-host-key /run/resealed-key; cmp /run/resealed-key /persist/credstore/ssh-host-key; rm /run/resealed-key")

    with subtest("missing TPM token falls back to SSH passphrase unlock"):
        # Test-only mutation of the virtual LUKS token, never production state.
        warbler.succeed(f"cryptsetup token remove --token-id 0 {disk}")
        warbler.shutdown()
        warbler.start()
        client.wait_until_succeeds("nc -z 192.168.1.3 2222")
        script = f"import pexpect; p=pexpect.spawn({ssh!r}, encoding='utf-8', timeout=120); p.expect('passphrase'); p.sendline({password!r}); p.expect(pexpect.EOF)"
        client.succeed("python3 -c " + shlex.quote(script))
        warbler.wait_for_unit("multi-user.target")
        warbler.succeed("test -e /run/warbler-initrd-networkd-started && test -e /run/warbler-initrd-sshd-started")
  '';
}
