{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "warbler-ai-harnesses";
  nodes.machine = { lib, ... }: {
    imports = [ ./ai-harnesses.nix ];
    # Exercise the optional compatibility adapter; production defaults to off.
    services.codex-ai.stdioForwarder.enable = true;
    users.users.cody.isNormalUser = true;
    services.openssh.enable = true;
    # Offline fixture for the mutable standalone layout; the real service uses
    # OpenAI's installer. Exercise the actual pinned daemon and updater logic.
    systemd.services.codex-ai.preStart = lib.mkBefore ''
      mkdir -p /home/cody-ai/.codex/packages/standalone/current/bin
      cp ${pkgs.codex}/bin/codex /home/cody-ai/.codex/packages/standalone/current/bin/codex
      chmod u+w /home/cody-ai/.codex/packages/standalone/current/bin/codex
    '';
    systemd.tmpfiles.rules = [
      "d /persist 0755 root root -"
      "d /run/secrets 0755 root root -"
      "f /persist/public-test 0644 root root -"
      "f /run/secrets/public-test 0644 root root -"
      "f /home/cody/private-test 0644 cody users -"
      "f /root/private-test 0644 root root -"
    ];
    environment.systemPackages = [ pkgs.python3 pkgs.jq ];
    virtualisation.memorySize = 2048;
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("codex-ai.service")
    machine.wait_until_succeeds("test -S /home/cody-ai/.codex/app-server-control/app-server-control.sock")
    assert machine.succeed("id -Gn cody-ai").strip() == "cody-ai"
    machine.fail("su - cody-ai -c 'sudo -n true'")
    machine.fail("su - cody-ai -c 'cat /home/cody/private-test'")
    machine.fail("su - cody-ai -c 'nix --extra-experimental-features nix-command store ping --store daemon'")
    machine.succeed("ssh-keygen -q -t ed25519 -N \"\" -f /root/ai-test-key")
    machine.succeed("install -d -m 700 -o cody-ai -g cody-ai /home/cody-ai/.ssh; cp /root/ai-test-key.pub /home/cody-ai/.ssh/authorized_keys; chown cody-ai:cody-ai /home/cody-ai/.ssh/authorized_keys")
    status, output = machine.execute("timeout 60 ssh -o StrictHostKeyChecking=accept-new -i /root/ai-test-key cody-ai@localhost 'python3 ${../../scripts/test-warbler-ai-rpc.py}'")
    if status != 0:
        print(machine.succeed("cat /home/cody-ai/.codex/app-server-daemon/*.stderr.log"))
    assert status == 0, output
    machine.fail("timeout 10 ssh -o StrictHostKeyChecking=accept-new -i /root/ai-test-key -W localhost:22 cody-ai@localhost")
    machine.fail("test -e /tmp/ai-private-test")
    machine.succeed("su - cody-ai -c 'codex app-server daemon start' | grep running")
    machine.succeed("su - cody-ai -c 'codex app-server daemon version'")
    machine.succeed("jq -e .remoteControlEnabled /home/cody-ai/.codex/app-server-daemon/settings.json")
    # The supervisor must restore a dead daemon without losing its sandbox.
    machine.succeed("kill -KILL $(jq -r .pid /home/cody-ai/.codex/app-server-daemon/app-server.pid)")
    machine.wait_until_succeeds("su - cody-ai -c 'codex app-server daemon version'", timeout=90)
    machine.succeed("systemctl restart codex-ai")
    machine.wait_until_succeeds("test -S /home/cody-ai/.codex/app-server-control/app-server-control.sock")
    machine.succeed("grep persisted /home/cody-ai/workspaces/proof")
    machine.succeed("systemctl stop codex-ai")
    machine.fail("su - cody-ai -c 'codex app-server daemon start'")
  '';
}
