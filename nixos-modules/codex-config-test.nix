{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "codex-config-activation";
  nodes.machine = {
    imports = [ ./codex-config.nix ];
    users.users.coder.isNormalUser = true;
    programs.codex-config.users = [ "coder" ];
    environment.systemPackages = [ pkgs.python3 ];
  };
  nodes.updater = {
    # Both Warbler AI environments import this same module.
    imports = [ ../hosts/warbler/ai-user-config.nix ];
    users.groups.cody-ai = { };
    users.users.cody-ai = { isNormalUser = true; group = "cody-ai"; };
    environment.systemPackages = [ pkgs.python3 ];
  };
  testScript = ''
    import shlex

    start_all()
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

    updater.wait_for_unit("multi-user.target")
    ai_path = "/home/cody-ai/.codex/config.toml"
    assert updater.succeed("stat -c '%U %a' " + ai_path).strip() == "cody-ai 600"
    updater.succeed("test -f " + ai_path + " && test ! -L " + ai_path)
    updater.succeed("printf %s " + shlex.quote(original) + " > " + ai_path)
    updater.succeed("rm -rf /home/cody-ai/.cache/uv")
    updater.succeed("/run/current-system/activate")
    updater.succeed("python3 -c " + shlex.quote(
        "import pathlib, tomllib; p=pathlib.Path('" + ai_path + "'); "
        "c=tomllib.loads(p.read_text()); assert '# keep me' in p.read_text(); "
        "assert c['sandbox_mode']=='workspace-write'; "
        "assert c['sandbox_workspace_write']['network_access']; "
        "assert '/custom' in c['sandbox_workspace_write']['writable_roots']; "
        "assert '/home/cody-ai/.cache/uv' in c['sandbox_workspace_write']['writable_roots']; "
        "assert pathlib.Path('/home/cody-ai/.cache/uv').is_dir()"
    ))
    updated = updater.succeed("cat " + ai_path)
    updater.succeed("/run/current-system/activate")
    assert updater.succeed("cat " + ai_path) == updated
    assert updater.succeed("stat -c '%U %a' " + ai_path).strip() == "cody-ai 600"

    # Read the default config through a real tmux server as the AI user.
    tmux = "runuser -u cody-ai -- /etc/profiles/per-user/cody-ai/bin/tmux -L ai-config-test "
    updater.succeed(tmux + "new-session -d -s config-test 'sleep 60'")
    assert updater.succeed(tmux + "show-options -gv prefix").strip() == "C-z"
    assert updater.succeed(tmux + "show-options -gv base-index").strip() == "1"
    updater.succeed(tmux + "kill-server")
  '';
}
