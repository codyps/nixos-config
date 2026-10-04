{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "warbler-ai-container";
  nodes = {
    host = { lib, ... }: {
      imports = [ ./ai-container.nix ];
      # Model the trusted Tailscale interface separately from the other LAN.
      services.tailscale.interfaceName = "testvpn";
      networking.dhcpcd.denyInterfaces = [ "testvpn" ];
      # Answer for the disposable interface only on its own MAC address.
      boot.kernel.sysctl."net.ipv4.conf.all.arp_ignore" = 1;
      virtualisation.vlans = [ 1 2 ];
      containers.ai.macvlans = lib.mkForce [ "eth1" ];
      containers.ai.config = {
        systemd.network.networks."10-lan".matchConfig.Name = lib.mkForce "mv-eth1";
        # Keep the test offline, exercising the foreground app server.
        nix.settings.flake-registry = "";
        systemd.user.timers.codex-ai-update.enable = lib.mkForce false;
        systemd.user.services.codex-ai.preStart = ''
          mkdir -p "$HOME/.codex/packages/standalone/current"
          cp -r ${import ./codex-test-package.nix { inherit pkgs; }}/. "$HOME/.codex/packages/standalone/current/"
          chmod -R u+w "$HOME/.codex/packages/standalone/current"
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
      virtualisation.diskSize = 4096;
      virtualisation.cores = 4;
      # Keep the shell checks offline, including the compiler/setup dependencies.
      virtualisation.additionalPaths = [ (pkgs.mkShell { packages = [ pkgs.hello ]; }) ];
    };
    client = { ... }: {
      virtualisation.vlans = [ 1 2 ];
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
    import json
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
    # /tmp is disk-backed, private from the host /tmp, and survives restart.
    assert host.succeed(inside + "findmnt -n -o FSTYPE -T /tmp").strip() != "tmpfs"
    client.succeed(ssh + shlex.quote("set -e; test $(stat -c %a /tmp) = 1777; echo scratch-proof > /tmp/ai-disk-proof; printf '#!/bin/sh\\nexit 0\\n' > /tmp/ai-exec-proof; chmod +x /tmp/ai-exec-proof; /tmp/ai-exec-proof"))
    host.succeed("grep scratch-proof /var/lib/warbler-ai/tmp/ai-disk-proof")
    host.fail("test -e /tmp/ai-disk-proof")
    host.fail("runuser -u cody-ai -- test -r /var/lib/warbler-ai/tmp/ai-disk-proof")
    # A disposable interface models tailscaled deleting and recreating its TUN.
    def create_vpn():
        host.succeed("ip link add testvpn link eth1 type macvlan mode bridge")
        host.succeed("ip address add 192.168.3.200/24 dev testvpn")
        host.succeed("ip link set testvpn up")
        host.wait_for_unit("ai-container-ssh.socket")
    client.succeed("ip address add 192.168.3.1/24 dev eth1")
    create_vpn()
    host.wait_until_succeeds("ip -4 address show ai-ssh | grep 10.79.0.1/24")
    host.wait_until_succeeds(inside + "ip -4 address show ai-ssh | grep 10.79.0.2/24")
    # Tailscale subnet traffic is SNATed to the host on this private link.
    # A service without a port exception must work there and stay blocked on LAN.
    client.succeed(ssh + shlex.quote("systemd-run --user --unit=ai-firewall-probe python3 -m http.server 8765 --bind 0.0.0.0"))
    host.wait_until_succeeds("${pkgs.curl}/bin/curl --fail --silent --max-time 3 http://10.79.0.2:8765/", timeout=30)
    client.fail("${pkgs.curl}/bin/curl --fail --silent --max-time 3 http://192.168.1.100:8765/")
    client.succeed(ssh + "systemctl --user stop ai-firewall-probe.service")
    def host_address(interface):
        addresses = json.loads(host.succeed(f"ip -j -4 address show {interface}"))[0]["addr_info"]
        return next(address["local"] for address in addresses if address["scope"] == "global")
    proxy_ssh = "ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -i /root/ai-key -p 2223 cody-ai@192.168.3.200 "
    assert client.succeed(proxy_ssh + "hostname").strip() == "warbler-ai"
    client.fail("nc -z -w 3 " + host_address("eth2") + " 2223")
    container_pid = host.succeed("systemctl show container@ai -p MainPID --value").strip()
    for _ in range(2):
        host.wait_for_unit("ai-container-ssh.service")
        old_index = host.succeed("cat /sys/class/net/testvpn/ifindex").strip()
        host.succeed("ip link delete testvpn")
        host.wait_until_succeeds("test $(systemctl show ai-container-ssh.socket -p ActiveState --value) = inactive")
        host.wait_until_succeeds("test $(systemctl show ai-container-ssh.service -p ActiveState --value) = inactive")
        create_vpn()
        assert host.succeed("cat /sys/class/net/testvpn/ifindex").strip() != old_index
        client.wait_until_succeeds(proxy_ssh + "true")
        assert host.succeed("systemctl show container@ai -p MainPID --value").strip() == container_pid
    # The private link must not replace the macvlan DHCP default route.
    host.succeed(inside + "ip -4 route show default | grep mv-eth1")
    host.fail(inside + "ip -4 route show default | grep ai-ssh")
    client.succeed(ssh + shlex.quote("set -e; test $(hostname) = warbler-ai; test $(id -un) = cody-ai; test ! -e /home/cody-ai/host-only; test ! -e /persist/host-only; /bin/bash -c 'echo bash-ok'; /bin/kill -0 $$; /usr/bin/env bash -c true; systemctl --user is-active codex-ai; test $(loginctl show-user cody-ai -p Linger --value) = yes; nix store ping --store daemon"))
    # Legacy and flake commands resolve the system's pinned nixpkgs without channels.
    assert client.succeed(ssh + "nix-instantiate --find-file nixpkgs").strip() == "${builtins.path { path = pkgs.path; name = "source"; }}"
    assert client.succeed(ssh + shlex.quote("nix-shell -p hello --run hello")).strip() == "Hello, world!"
    assert client.succeed(ssh + "nix eval --offline --raw nixpkgs#hello.outPath").strip() == "${pkgs.hello}"
    # Bash loads both hooks; Atuin records and retrieves history via its user daemon.
    client.succeed(ssh + shlex.quote("bash -ic 'set -e; declare -F __atuin_precmd; declare -F _direnv_hook'"))
    client.succeed(ssh + shlex.quote("set -e; export ATUIN_SESSION=$(atuin uuid); id=$(atuin history start -- echo ai-history-proof); atuin history end --exit 0 --duration 1 -- $id"))
    client.wait_until_succeeds(ssh + shlex.quote("ATUIN_SESSION=$(atuin uuid) atuin search --cmd-only ai-history-proof | grep -Fx 'echo ai-history-proof'"), timeout=30)
    client.succeed(ssh + "systemctl --user is-active atuin-daemon.service")
    # direnv loads a flake shell and reuses nix-direnv's cached environment.
    shell_dir = "/home/cody-ai/workspaces/shell-test"
    client.succeed(ssh + shlex.quote("mkdir -p " + shell_dir))
    client.succeed(ssh + shlex.quote("cat > " + shell_dir + "/flake.nix <<'EOF'\n" + """
    {
      inputs.nixpkgs.url = "path:${builtins.path { path = pkgs.path; name = "source"; }}";
      outputs = { nixpkgs, ... }: {
        devShells.${pkgs.stdenv.hostPlatform.system}.default =
          nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.mkShell {
            packages = [ nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.hello ];
            shellHook = "export AI_SHELL_PROOF=flake";
          };
      };
    }
    """ + "\nEOF"))
    client.succeed(ssh + shlex.quote("cd " + shell_dir + "; printf 'use flake . --offline\\n' > .envrc; direnv allow"))
    for _ in range(2):
        client.succeed(ssh + shlex.quote("cd " + shell_dir + "; direnv exec . bash -c 'test \"$AI_SHELL_PROOF\" = flake && hello'"))
    client.succeed(ssh + shlex.quote("test -n \"$(find " + shell_dir + "/.direnv -name 'flake-profile*' -type l -print -quit)\""))
    client.succeed(ssh + shlex.quote("systemd-run --user --wait --pipe direnv exec " + shell_dir + " bash -c 'test \"$AI_SHELL_PROOF\" = flake && hello'"))
    assert client.succeed(ssh + "'git config user.name'").strip() == "Cody P Schafer"
    assert client.succeed(ssh + "'git config user.email'").strip() == "dev@codyps.com"
    # Same service access from a background task, without an interactive login.
    client.succeed(ssh + shlex.quote("systemd-run --user --wait --pipe /bin/bash -lc 'test -S /run/user/1001/bus; systemctl --user is-active codex-ai; command -v git uv pip node; touch ~/workspaces/service-proof'"))
    # Exercise the real control socket and a Codex service child, no model/auth.
    client.succeed(ssh + shlex.quote("${pkgs.python3.withPackages (p: [ p.websockets ])}/bin/python3 ${../../scripts/test-warbler-ai-container-rpc.py}"))
    # A real active turn must survive repeated drain requests. This uses a
    # separate server and local fake model; no provider login is needed.
    client.succeed(ssh + shlex.quote("${pkgs.python3.withPackages (p: [ p.websockets ])}/bin/python3 ${../../scripts/test-codex-drain.py} /home/cody-ai/.codex/packages/standalone/current/bin/codex"))
    old_pid = client.succeed(ssh + "systemctl --user show codex-ai --property=MainPID --value").strip()
    client.succeed(ssh + "sys restart-codex")
    client.wait_until_succeeds(ssh + shlex.quote("pid=$(systemctl --user show codex-ai --property=MainPID --value); test $pid -gt 0 && test $pid != " + old_pid))
    client.wait_until_succeeds(ssh + "codex app-server daemon version")
    host.succeed(inside + "test -f /home/cody-ai/workspaces/service-proof")
    host.fail("test -e /home/cody-ai/workspaces/service-proof")
    host.succeed("systemctl restart container@ai")
    host.wait_until_succeeds(inside + "test -S /run/user/1001/bus")
    host.wait_until_succeeds(inside + "test -S /home/cody-ai/.codex/app-server-control/app-server-control.sock")
    host.succeed(inside + "test -f /home/cody-ai/workspaces/service-proof")
    host.succeed(inside + "test -f /home/cody-ai/workspaces/codex-proof")
    host.succeed(inside + "grep scratch-proof /tmp/ai-disk-proof")
    client.wait_until_succeeds(proxy_ssh + "true")
    host.succeed("test -f /home/cody-ai/host-only")
  '';
}
