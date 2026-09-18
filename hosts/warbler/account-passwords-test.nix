{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "warbler-account-passwords";
  nodes.machine = { ... }: {
    imports = [ ./account-passwords.nix ];
    users.users.cody.isNormalUser = true;
    environment.systemPackages = [ pkgs.shadow (pkgs.python3.withPackages (p: [ p.pexpect ])) ];
  };
  testScript = ''
    machine.start(allow_reboot=True)
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /persist; mount --bind /persist /persist; install -d -m 700 /run/account-passwords")
    # Synthetic test passwords, never production credentials.
    initial = "Abcdef-ghijkl-mnopq7-RS"
    changed = "Newpass-Another-Value79"
    machine.succeed(f"umask 077; printf %s {initial} > /run/account-passwords/root; printf %s {initial} > /run/account-passwords/cody")
    machine.succeed("warbler-account-passwords initialize --password-dir /run/account-passwords")
    machine.succeed("/run/current-system/activate")
    machine.succeed("test $(stat -c %a /persist/shadow.d) = 700; test $(stat -c %a /persist/shadow.d/cody) = 600")
    machine.succeed("test $(getent shadow cody | cut -d: -f2) = $(cat /persist/shadow.d/cody)")

    with subtest("normal passwd persists a user change"):
        script = f"import pexpect; p=pexpect.spawn('su', ['-', 'cody', '-c', 'passwd'], encoding='utf-8', timeout=30); p.expect('[Cc]urrent.*password:'); p.sendline({initial!r}); p.expect('[Nn]ew password:'); p.sendline({changed!r}); p.expect('[Rr]etype.*password:'); p.sendline({changed!r}); p.expect(pexpect.EOF); p.close(); assert p.exitstatus == 0"
        import shlex
        machine.succeed("python3 -c " + shlex.quote(script))
        changed_hash = machine.succeed("cat /persist/shadow.d/cody")
        machine.succeed("test $(getent shadow cody | cut -d: -f2) = $(cat /persist/shadow.d/cody)")
        machine.succeed("warbler-account-passwords initialize --password-dir /run/account-passwords")
        assert changed_hash == machine.succeed("cat /persist/shadow.d/cody")

    with subtest("administrator chpasswd persists root password"):
        machine.succeed(f"printf 'root:%s\\n' {changed} | chpasswd")
        machine.succeed("test $(getent shadow root | cut -d: -f2) = $(cat /persist/shadow.d/root)")

    with subtest("immutable account activation preserves passwords and removes extra users"):
        machine.succeed("useradd unwanted; /run/current-system/activate")
        machine.fail("getent passwd unwanted")
        assert changed_hash == machine.succeed("cat /persist/shadow.d/cody")
        machine.succeed("test $(getent shadow cody | cut -d: -f2) = $(cat /persist/shadow.d/cody)")

    with subtest("password hash survives shadow recreation and reboot"):
        machine.succeed("rm /etc/shadow; /run/current-system/activate")
        machine.succeed("test $(getent shadow cody | cut -d: -f2) = $(cat /persist/shadow.d/cody)")
        machine.reboot()
        machine.wait_for_unit("multi-user.target")
        assert changed_hash == machine.succeed("cat /persist/shadow.d/cody")
        machine.succeed("test $(getent shadow cody | cut -d: -f2) = $(cat /persist/shadow.d/cody)")
        script = f"import pexpect; p=pexpect.spawn('su', ['-s', '/bin/sh', 'nobody', '-c', 'su - cody -c whoami'], encoding='utf-8', timeout=30); p.expect('[Pp]assword:'); p.sendline({changed!r}); p.expect('cody'); p.expect(pexpect.EOF); p.close(); assert p.exitstatus == 0"
        machine.succeed("python3 -c " + shlex.quote(script))
  '';
}
