"""Smoke-test a built Home Manager profile: python3 scripts/test-mbx.py PROFILE."""
import os, pathlib, subprocess, sys, tempfile
profile = pathlib.Path(sys.argv[1])
# Keep Unix socket paths short, including on macOS with its long default TMPDIR.
with tempfile.TemporaryDirectory(prefix='mbx-nix-', dir='/tmp') as tmp:
    root = pathlib.Path(tmp)
    env = os.environ.copy()
    for key in ['CARGO', 'CARGO_TARGET_DIR', 'RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER', 'MBX_SOCKET', 'MBX_DISABLE', 'MBX_CARGO_SHIM_MODE', 'MBX_CARGO_SHIM_PATH']:
        env.pop(key, None)
    env.update(PATH=str(profile / 'bin') + ':' + env['PATH'], MBX_CACHE_DIR=str(root / 'cache'), MBX_TARGET_ROOT=str(root / 'targets'), CARGO_INCREMENTAL='0')
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
    print('PASS: passthrough, cached cargo, explicit mbx, toolchain selection, nested cargo, PATH, and MBX_DISABLE')
