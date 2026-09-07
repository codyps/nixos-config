"""Smoke-test a Home Manager generation: python3 scripts/test-mbx.py GENERATION."""
import json, os, pathlib, shutil, subprocess, sys, tempfile
generation = pathlib.Path(sys.argv[1])
profile = generation / "home-path"
# Keep Unix socket paths short, including on macOS with its long default TMPDIR.
with tempfile.TemporaryDirectory(prefix='mbx-nix-', dir='/tmp') as tmp:
    root = pathlib.Path(tmp)
    env = os.environ.copy()
    for key in ['CARGO', 'CARGO_TARGET_DIR', 'RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER', 'MBX_SOCKET', 'MBX_DISABLE', 'MBX_CARGO_SHIM_MODE', 'MBX_CARGO_SHIM_PATH']:
        env.pop(key, None)
    original_home = pathlib.Path.home()
    test_home = root / 'home'
    relative_data = pathlib.Path('Library/Application Support' if sys.platform == 'darwin' else '.local/share')
    relative_shim = relative_data / 'mbx/bin'
    shim = test_home / relative_shim
    shim.mkdir(parents=True)
    for name in ['cargo', 'mbx-target']:
        shutil.copyfile(generation / 'home-files' / relative_shim / name, shim / name)
    (shim / 'cargo').chmod(0o755)
    env.update(HOME=str(test_home), XDG_DATA_HOME=str(test_home / relative_data),
               CARGO_HOME=env.get('CARGO_HOME', str(original_home / '.cargo')),
               RUSTUP_HOME=env.get('RUSTUP_HOME', str(original_home / '.rustup')),
               PATH=str(profile / 'bin') + ':' + env['PATH'],
               MBX_CACHE_DIR=str(root / 'cache'), MBX_TARGET_ROOT=str(root / 'targets'), CARGO_INCREMENTAL='0')
    env.pop('__HM_SESS_VARS_SOURCED', None)
    # Exercise the generated PATH setup, relocating only this user's home.
    session = (profile / 'etc/profile.d/hm-session-vars.sh').read_text()
    session = session.replace(str(original_home), str(test_home))
    exported = subprocess.check_output(['bash', '-c', session + '\nenv -0'], env=env)
    env = dict(item.decode().split('=', 1) for item in exported.split(b'\0') if item)
    assert pathlib.Path(shutil.which('cargo', path=env['PATH'])) == shim / 'cargo'

    (root / 'Cargo.toml').write_text('[package]\nname="mbx-nix-smoke"\nversion="0.1.0"\nedition="2021"\n')
    (root / 'src').mkdir()
    (root / 'src/lib.rs').write_text('pub fn answer() -> u32 { 42 }\n')
    (root / 'build.rs').write_text('''fn main() {
        let expected = std::env::var("EXPECT_MBX").unwrap() == "1";
        assert_eq!(std::env::var_os("MBX_SOCKET").is_some(), expected);
        assert!(std::env::var_os("MBX_CARGO_SHIM_MODE").is_none());
        assert!(std::env::var_os("MBX_CARGO_SHIM_PATH").is_none());
        assert!(std::process::Command::new("cargo").arg("--version").status().unwrap().success());
        assert!(std::process::Command::new("git").arg("--version").status().unwrap().success());
        println!("cargo:rerun-if-env-changed=EXPECT_MBX");
    }''')
    def run(args, extra=None):
        print('+', ' '.join(args), flush=True)
        try:
            return subprocess.run(args, cwd=root, env=env | (extra or {}), check=True, timeout=180, capture_output=True, text=True)
        except subprocess.CalledProcessError as error:
            print(error.stdout, error.stderr, file=sys.stderr)
            raise
    print(run(['cargo', '--version']).stdout.strip())
    print(run(['mbx', '--version']).stdout.strip())
    run(['cargo', 'metadata', '--offline', '--format-version=1', '--no-deps'])
    assert not (root / 'cache').exists(), 'passthrough created a cache'
    run(['cargo', 'check', '--offline'], {'EXPECT_MBX':'1'})
    assert (root / 'cache').is_dir(), 'cargo did not initialize mbx'
    run(['mbx', 'check', '--offline'], {'EXPECT_MBX':'1'})
    toolchain = subprocess.check_output(['rustup', 'show', 'active-toolchain'], env=env, text=True).split()[0]
    run(['cargo', '+' + toolchain, 'check', '--offline'], {'EXPECT_MBX':'1'})
    run(['cargo', 'check', '--offline'], {'EXPECT_MBX':'0', 'MBX_DISABLE':'1', 'CARGO_TARGET_DIR':str(root / 'disabled-target')})
    report = json.loads(run(['mbx', 'doctor', '--json']).stdout)
    setup = next(check for check in report['checks'] if check['name'] == 'setup')
    assert setup['severity'] == 'pass', setup
    print(setup['detail'])
    print('PASS: doctor setup, passthrough, cached cargo, explicit mbx, toolchain selection, nested cargo, PATH, and MBX_DISABLE')
