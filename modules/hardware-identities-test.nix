{ pkgs }:
let
  fixtures = builtins.fromJSON (builtins.readFile ../config/hardware-fixtures/hardware-identities.json);
  uuid = fixtures.mifflin.storage.fileSystems."/".uuid;
  alias = "/dev/disk/by-hardware/mifflin-storage-fileSystems-_-uuid";
in
pkgs.testers.runNixOSTest {
  name = "hardware-live-aliases";
  nodes.machine = { lib, ... }: {
    networking.hostName = "mifflin";
    # This test switches userspace; its VM boots directly without a bootloader.
    boot.loader.supportsInitrdSecrets = lib.mkOverride 5 true;
    environment.systemPackages = [ pkgs.e2fsprogs pkgs.util-linux ];
    specialisation.aliases.configuration = {
      imports = [ ./hardware-identities.nix ];
      services.hardwareIdentities.allowFixtures = true;
      virtualisation.fileSystems."/mnt/test-data" = {
        device = alias;
        fsType = "ext4";
      };
    };
  };
  testScript = ''
    import shlex

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("truncate -s 64M /tmp/test-disk")
    loop = machine.succeed("losetup --find --show /tmp/test-disk").strip()
    machine.succeed(f"mkfs.ext4 -F -U ${uuid} {shlex.quote(loop)}")
    machine.succeed("udevadm trigger --action=change --subsystem-match=block --settle")
    machine.succeed(f"mkdir -p /mnt/test-data; mount {shlex.quote(loop)} /mnt/test-data")
    machine.succeed("echo preserved > /mnt/test-data/sentinel")

    generation = "/run/current-system/specialisation/aliases"
    machine.succeed(f"{generation}/sw/bin/sys hardware-provision --fixtures")
    machine.succeed("test -b ${alias}")
    device = machine.succeed("systemd-escape --path --suffix=device ${alias}").strip()
    # Provisioning creates a usable link, but PID 1 has not seen an alias event.
    machine.fail(f"systemctl is-active {shlex.quote(device)}")

    with subtest("live activation publishes device aliases before restarting mounts"):
        machine.succeed(f"timeout 60 {generation}/bin/switch-to-configuration test")
        machine.succeed(f"systemctl is-active {shlex.quote(device)}")
        mount = machine.succeed("systemd-escape --path --suffix=mount /mnt/test-data").strip()
        machine.succeed(f"systemctl restart {shlex.quote(mount)}")
        machine.succeed("findmnt /mnt/test-data")
        assert machine.succeed("cat /mnt/test-data/sentinel").strip() == "preserved"
        machine.fail("systemctl is-active emergency.target")
  '';
}
