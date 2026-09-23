{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "warbler-ai-container";
  nodes = {
    host = { lib, ... }: {
      imports = [ ./ai-container.nix ];
      containers.ai.macvlans = lib.mkForce [ "eth1" ];
      containers.ai.config = {
        systemd.network.networks."10-lan".matchConfig.Name = lib.mkForce "mv-eth1";
        # Keep the test offline, exercising the real bootstrap and updater.
        systemd.user.services.codex-ai.preStart = ''
          mkdir -p "$HOME/.codex/packages/standalone/current/bin"
          # Use the binary: Nixpkgs' wrapper prepends its unpatched Bubblewrap.
          cp ${pkgs.codex}/bin/.codex-wrapped "$HOME/.codex/packages/standalone/current/bin/codex"
          chmod u+w "$HOME/.codex/packages/standalone/current/bin/codex"
        '';
      };
      nix.settings.allowed-users = [ "root" "cody-ai" ];
      users.groups.cody-ai.gid = 993;
      users.users.cody-ai = { isNormalUser = true; uid = 1001; group = "cody-ai"; };
      systemd.tmpfiles.rules = [
        "f /home/cody-ai/host-only 0644 root root - host-only"
        "d /persist 0755 root root -"
        "f /persist/host-only 0644 root root - host-only"
      ];
      virtualisation.memorySize = 4096;
      virtualisation.cores = 4;
    };
    client = { ... }: {
      services.dnsmasq = {
        enable = true;
        settings = {
          interface = "eth1";
          bind-interfaces = true;
          dhcp-range = "192.168.1.100,192.168.1.150,255.255.255.0,1h";
          dhcp-host = "02:57:41:52:41:49,192.168.1.100";
        };
      };
      networking.firewall.allowedUDPPorts = [ 67 ];
    };
  };
  testScript = ''
    import shlex

    start_all()
    client.wait_for_unit("dnsmasq.service")
    host.wait_for_unit("container@ai.service")
    inside = "nixos-container run ai -- "
    host.wait_until_succeeds(inside + "test -S /run/user/1001/bus")
    host.wait_until_succeeds(inside + "test -S /home/cody-ai/.codex/app-server-control/app-server-control.sock")
    host.wait_until_succeeds(inside + "ip -4 address show mv-eth1 | grep 192.168.1.100")
    client.succeed("ssh-keygen -q -t ed25519 -N \"\" -f /root/ai-key")
    key = client.succeed("cat /root/ai-key.pub").strip()
    host.succeed(inside + "install -d -m 700 -o cody-ai -g cody-ai /home/cody-ai/.ssh")
    host.succeed(inside + "sh -c " + shlex.quote("echo " + shlex.quote(key) + " > /home/cody-ai/.ssh/authorized_keys; chown cody-ai:cody-ai /home/cody-ai/.ssh/authorized_keys"))
    ssh = "ssh -n -o StrictHostKeyChecking=accept-new -i /root/ai-key cody-ai@192.168.1.100 "
    client.wait_until_succeeds(ssh + "true")
    client.succeed(ssh + shlex.quote("set -e; test $(hostname) = warbler-ai; test $(id -un) = cody-ai; test ! -e /home/cody-ai/host-only; test ! -e /persist/host-only; /bin/bash -c 'echo bash-ok'; /bin/kill -0 $$; /usr/bin/env bash -c true; systemctl --user is-active codex-ai; test $(loginctl show-user cody-ai -p Linger --value) = yes; nix store ping --store daemon"))
    # Same service access from a background task, without an interactive login.
    client.succeed(ssh + shlex.quote("systemd-run --user --wait --pipe /bin/bash -lc 'test -S /run/user/1001/bus; systemctl --user is-active codex-ai; command -v git uv pip node; touch ~/workspaces/service-proof'"))
    # Exercise the real control socket and a Codex service child, no model/auth.
    client.succeed(ssh + shlex.quote("${pkgs.python3.withPackages (p: [ p.websockets ])}/bin/python3 ${../../scripts/test-warbler-ai-container-rpc.py}"))
    host.succeed(inside + "test -f /home/cody-ai/workspaces/service-proof")
    host.fail("test -e /home/cody-ai/workspaces/service-proof")
    host.succeed("systemctl restart container@ai")
    host.wait_until_succeeds(inside + "test -S /run/user/1001/bus")
    host.wait_until_succeeds(inside + "test -S /home/cody-ai/.codex/app-server-control/app-server-control.sock")
    host.succeed(inside + "test -f /home/cody-ai/workspaces/service-proof")
    host.succeed(inside + "test -f /home/cody-ai/workspaces/codex-proof")
    host.succeed("test -f /home/cody-ai/host-only")
  '';
}
