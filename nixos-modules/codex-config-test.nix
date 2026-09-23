{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "codex-config-activation";
  nodes.machine = {
    imports = [ ./codex-config.nix ];
    users.users.coder.isNormalUser = true;
    programs.codex-config.users = [ "coder" ];
    environment.systemPackages = [ pkgs.python3 ];
  };
  testScript = ''
    import shlex

    machine.start()
    machine.wait_for_unit("multi-user.target")
    path = "/home/coder/.codex/config.toml"
    assert machine.succeed("stat -c '%U %a' " + path).strip() == "coder 600"
    machine.succeed("test -f " + path + " && test ! -L " + path)
    machine.succeed("python3 -c " + shlex.quote(
        "import tomllib; c=tomllib.load(open('" + path + "','rb')); "
        "assert c['sandbox_mode']=='workspace-write'; "
        "assert c['sandbox_workspace_write']['network_access']; "
        "assert '/home/coder/.cache/uv' in c['sandbox_workspace_write']['writable_roots']"
    ))
    # Simulate Codex changing the file, then activate again: leave it intact.
    original = '# keep me\nsandbox_mode = "read-only"\n[sandbox_workspace_write]\nwritable_roots = ["/custom"]\n'
    machine.succeed("printf %s " + shlex.quote(original) + " > " + path)
    machine.succeed("/run/current-system/activate")
    assert machine.succeed("cat " + path) == original
    machine.succeed("runuser -u coder -- codex-configure")
    machine.succeed("python3 -c " + shlex.quote(
        "import tomllib; c=tomllib.load(open('" + path + "','rb')); "
        "assert c['sandbox_mode']=='workspace-write'; "
        "assert '/custom' in c['sandbox_workspace_write']['writable_roots']; "
        "assert '/home/coder/.cache/uv' in c['sandbox_workspace_write']['writable_roots']"
    ))
  '';
}
