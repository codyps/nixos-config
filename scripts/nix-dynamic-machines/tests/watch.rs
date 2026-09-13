#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant};

static NEXT: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    dir: PathBuf,
    child: Option<Child>,
}

impl Fixture {
    fn new(source: &str, script: &str) -> Self {
        let dir = std::env::temp_dir().join(format!(
            "dynamic-watch-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&dir).unwrap();
        fs::write(dir.join("candidates"), source).unwrap();
        fs::write(dir.join("nix"), format!("#!/bin/sh\n{script}\n")).unwrap();
        fs::set_permissions(dir.join("nix"), fs::Permissions::from_mode(0o755)).unwrap();
        Self { dir, child: None }
    }

    fn command(&self) -> Command {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_nix-dynamic-machines"));
        cmd.current_dir(&self.dir)
            .args([
                "--candidates",
                "candidates",
                "--output",
                "machines",
                "--nix",
                "./nix",
                "--timeout",
                "30",
                "--parallelism",
                "2",
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null());
        cmd
    }

    fn start(&mut self, extra: &[&str]) {
        self.child = Some(self.command().arg("--watch").args(extra).spawn().unwrap());
    }

    fn signal(&self, signal: i32) {
        unsafe extern "C" {
            fn kill(pid: i32, signal: i32) -> i32;
        }
        // SAFETY: targets only our unreaped test child.
        assert_eq!(
            unsafe { kill(self.child.as_ref().unwrap().id() as i32, signal) },
            0
        );
    }

    fn read(&self, file: &str) -> String {
        fs::read_to_string(self.dir.join(file)).unwrap_or_default()
    }

    fn until(&self, condition: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(15);
        while !condition() {
            assert!(
                Instant::now() < deadline,
                "watcher condition timed out in {}",
                self.dir.display()
            );
            thread::sleep(Duration::from_millis(20));
        }
    }

    fn stop(&mut self, signal: i32) {
        self.signal(signal);
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(status) = self.child.as_mut().unwrap().try_wait().unwrap() {
                assert!(status.success(), "watcher failed: {status}");
                self.child = None;
                break;
            }
            assert!(Instant::now() < deadline, "watcher did not stop");
            thread::sleep(Duration::from_millis(20));
        }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn watcher_publishes_without_batch_barrier_and_reloads_safely() {
    let mut f = Fixture::new("always ssh://docker\nprobe ssh://fast\nprobe ssh://slow", "printf '%s\\n' \"$4\" >> calls\ncase \"$4\" in *slow*) touch slow-started; sleep 30;; esac\nexit 0");
    f.start(&[]);
    f.until(|| {
        f.read("machines") == "ssh://docker\nssh://fast\n" && f.dir.join("slow-started").exists()
    });
    assert!(!f.read("calls").contains("docker"));
    assert!(!f.command().arg("--force").status().unwrap().success());
    fs::write(f.dir.join("candidates"), "invalid").unwrap();
    f.signal(1);
    thread::sleep(Duration::from_millis(300));
    assert_eq!(f.read("machines"), "ssh://docker\nssh://fast\n");
    fs::write(
        f.dir.join("candidates"),
        "always ssh://docker\nprobe ssh://new",
    )
    .unwrap();
    f.signal(1);
    f.until(|| f.read("machines") == "ssh://docker\nssh://new\n");
    f.signal(1);
    f.until(|| {
        f.read("calls")
            .lines()
            .filter(|line| *line == "ssh://new")
            .count()
            == 2
    });
    f.stop(15);
    assert!(!f.read("machines").contains("slow"));
    assert!(
        f.command().status().unwrap().success(),
        "shutdown must release the output lock"
    );
}

#[test]
fn internal_deadlines_retry_and_local_errors_preserve_membership() {
    let mut f = Fixture::new(
        "always ssh://docker\nprobe ssh://remote",
        "printf x >> calls\ntest -f healthy",
    );
    f.start(&[
        "--retry-interval",
        "1",
        "--max-retry-interval",
        "2",
        "--healthy-interval",
        "60",
    ]);
    f.until(|| f.read("machines.state.json").contains("\"failures\": 1"));
    assert_eq!(f.read("machines"), "ssh://docker\n");
    fs::write(f.dir.join("healthy"), "").unwrap();
    f.until(|| f.read("machines") == "ssh://docker\nssh://remote\n");
    assert_eq!(f.read("calls"), "xx");
    fs::remove_file(f.dir.join("nix")).unwrap();
    f.signal(1);
    thread::sleep(Duration::from_millis(400));
    assert_eq!(f.read("machines"), "ssh://docker\nssh://remote\n");
    f.stop(2);
}

#[test]
fn shutdown_cancels_probe_descendants() {
    let mut f = Fixture::new(
        "always ssh://docker\nprobe ssh://slow",
        "sh -c 'trap \"\" TERM; touch started; sleep 2; touch survived' &\nwait",
    );
    f.start(&[]);
    f.until(|| f.dir.join("started").exists());
    f.stop(15);
    thread::sleep(Duration::from_millis(2200));
    assert!(
        !f.dir.join("survived").exists(),
        "descendant survived cancellation"
    );
    assert_eq!(f.read("machines"), "ssh://docker\n");
}

#[test]
fn saturated_scheduler_queues_builders_without_overlap() {
    let mut f = Fixture::new(
        "probe ssh://first\nprobe ssh://second\nprobe ssh://third",
        "printf '%s\\n' \"$4\" >> calls\nwhile ! test -f release; do sleep 0.1; done\nexit 0",
    );
    f.start(&["--parallelism", "1"]);
    f.until(|| f.read("calls").lines().count() == 1);
    thread::sleep(Duration::from_millis(300));
    assert_eq!(f.read("calls").lines().count(), 1);
    fs::write(f.dir.join("release"), "").unwrap();
    f.until(|| f.read("machines").lines().count() == 3);
    assert_eq!(f.read("calls").lines().count(), 3);
    f.stop(15);
}

#[test]
fn always_only_watcher_never_launches_even_on_force_and_reload() {
    let mut f = Fixture::new("always ssh://docker", "touch called; exit 0");
    f.start(&["--force"]);
    f.until(|| f.read("machines") == "ssh://docker\n");
    fs::write(
        f.dir.join("candidates"),
        "always ssh://docker\nalways ssh://second",
    )
    .unwrap();
    f.signal(1);
    f.until(|| f.read("machines") == "ssh://docker\nssh://second\n");
    f.stop(15);
    assert!(!f.dir.join("called").exists());
}
