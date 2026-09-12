use std::env;
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitCode, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
#[cfg(unix)]
use std::os::unix::process::CommandExt;

const USAGE: &str = "Usage: nix-dynamic-machines --candidates PATH --output PATH [OPTIONS]

Options:
  --nix PATH              nix executable to use (default: nix)
  --timeout SECONDS       timeout for each probe (default: 3)
  --parallelism COUNT     maximum concurrent probes (default: 8)
  -h, --help              show this help

Each non-comment candidate line is `probe MACHINE_SPEC` or `always MACHINE_SPEC`,
where MACHINE_SPEC is one legacy Nix builders/machines line.";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Mode {
    Probe,
    Always,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Candidate {
    mode: Mode,
    machine_line: String,
    probe_uri: String,
}

#[derive(Debug)]
struct Args {
    candidates: PathBuf,
    output: PathBuf,
    nix: OsString,
    timeout: Duration,
    parallelism: usize,
}

fn main() -> ExitCode {
    match run(env::args_os().skip(1)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("nix-dynamic-machines: {message}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: impl Iterator<Item = OsString>) -> Result<(), String> {
    let Some(args) = parse_args(args)? else {
        println!("{USAGE}");
        return Ok(());
    };
    let source = fs::read_to_string(&args.candidates)
        .map_err(|e| format!("cannot read {}: {e}", args.candidates.display()))?;
    let candidates = parse_candidates(&source)?;
    let healthy = reconcile(&candidates, &args.nix, args.timeout, args.parallelism)?;
    let contents = render(&candidates, &healthy);
    let changed = atomic_write_if_changed(&args.output, contents.as_bytes())
        .map_err(|e| format!("cannot update {}: {e}", args.output.display()))?;
    eprintln!(
        "nix-dynamic-machines: {} of {} candidates enabled{}",
        healthy.iter().filter(|healthy| **healthy).count(),
        candidates.len(),
        if changed {
            " (updated)"
        } else {
            " (unchanged)"
        }
    );
    Ok(())
}

fn parse_args(mut args: impl Iterator<Item = OsString>) -> Result<Option<Args>, String> {
    let mut candidates = None;
    let mut output = None;
    let mut nix = OsString::from("nix");
    let mut timeout = Duration::from_secs(3);
    let mut parallelism = 8;

    while let Some(arg) = args.next() {
        let text = arg
            .to_str()
            .ok_or_else(|| "arguments must be valid UTF-8".to_owned())?;
        let value = |args: &mut dyn Iterator<Item = OsString>, option: &str| {
            args.next()
                .ok_or_else(|| format!("{option} requires a value"))
        };
        match text {
            "-h" | "--help" => return Ok(None),
            "--candidates" => candidates = Some(PathBuf::from(value(&mut args, text)?)),
            "--output" => output = Some(PathBuf::from(value(&mut args, text)?)),
            "--nix" => nix = value(&mut args, text)?,
            "--timeout" => {
                let raw = value(&mut args, text)?;
                let seconds = raw
                    .to_str()
                    .and_then(|s| s.parse::<f64>().ok())
                    .filter(|n| n.is_finite() && *n > 0.0)
                    .ok_or_else(|| "--timeout must be a positive number".to_owned())?;
                timeout = Duration::from_secs_f64(seconds);
            }
            "--parallelism" => {
                parallelism = value(&mut args, text)?
                    .to_str()
                    .and_then(|s| s.parse().ok())
                    .filter(|n| *n > 0)
                    .ok_or_else(|| "--parallelism must be a positive integer".to_owned())?;
            }
            _ => return Err(format!("unknown argument {text:?}\n\n{USAGE}")),
        }
    }

    Ok(Some(Args {
        candidates: candidates.ok_or_else(|| "--candidates is required".to_owned())?,
        output: output.ok_or_else(|| "--output is required".to_owned())?,
        nix,
        timeout,
        parallelism,
    }))
}

fn parse_candidates(source: &str) -> Result<Vec<Candidate>, String> {
    source
        .lines()
        .enumerate()
        .filter_map(|(index, raw)| {
            let line = raw.split_once('#').map_or(raw, |(before, _)| before).trim();
            if line.is_empty() {
                return None;
            }
            Some(parse_candidate(line).map_err(|e| format!("line {}: {e}", index + 1)))
        })
        .collect()
}

fn parse_candidate(line: &str) -> Result<Candidate, String> {
    let (mode, machine_line) = line
        .split_once(char::is_whitespace)
        .ok_or_else(|| "expected `probe MACHINE_SPEC` or `always MACHINE_SPEC`".to_owned())?;
    let mode = match mode {
        "probe" => Mode::Probe,
        "always" => Mode::Always,
        _ => return Err(format!("unknown mode {mode:?}")),
    };
    let machine_line = machine_line.trim();
    let fields: Vec<_> = machine_line.split_whitespace().collect();
    if fields.is_empty() || fields.len() > 8 {
        return Err("machine specification must contain between 1 and 8 fields".to_owned());
    }
    let mut uri = fields[0].to_owned();
    if machine_line.contains(';') || fields[0].starts_with('@') || fields[0] == "-" {
        return Err("expected a single SSH machine, without includes or semicolons".to_owned());
    }
    if !uri.contains("://") && !uri.contains('/') {
        uri = format!("ssh://{uri}");
    }
    let host = uri
        .strip_prefix("ssh://")
        .or_else(|| uri.strip_prefix("ssh-ng://"))
        .ok_or_else(|| "only ssh:// and ssh-ng:// builders are supported".to_owned())?;
    let host = host
        .split('?')
        .next()
        .unwrap_or("")
        .rsplit('@')
        .next()
        .unwrap_or("");
    if host.is_empty() || host.starts_with('-') || host.contains('/') {
        return Err("invalid SSH builder hostname".to_owned());
    }
    if let Some(jobs) = field(&fields, 3) {
        jobs.parse::<u32>()
            .ok()
            .filter(|n| *n > 0)
            .ok_or_else(|| "maxJobs must be a positive unsigned integer".to_owned())?;
    }
    if let Some(speed) = field(&fields, 4) {
        speed
            .parse::<f32>()
            .ok()
            .filter(|n| n.is_finite() && *n >= 0.0)
            .ok_or_else(|| "speedFactor must be finite and nonnegative".to_owned())?;
    }
    if let Some(key) = field(&fields, 7) {
        let unpadded = key.trim_end_matches('=');
        let padding = key.len() - unpadded.len();
        if key.len() % 4 != 0
            || padding > 2
            || unpadded.is_empty()
            || !unpadded
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/')
        {
            return Err("public host key must be base64 encoded".to_owned());
        }
    }
    if uri.starts_with("ssh://") || uri.starts_with("ssh-ng://") {
        if let Some(key) = field(&fields, 2) {
            add_query_parameter(&mut uri, "ssh-key", key);
        }
        if let Some(host_key) = field(&fields, 7) {
            add_query_parameter(&mut uri, "base64-ssh-public-host-key", host_key);
        }
    }
    Ok(Candidate {
        mode,
        machine_line: machine_line.to_owned(),
        probe_uri: uri,
    })
}

fn field<'a>(fields: &'a [&str], index: usize) -> Option<&'a str> {
    fields
        .get(index)
        .copied()
        .filter(|value| !value.is_empty() && *value != "-")
}

fn add_query_parameter(uri: &mut String, name: &str, value: &str) {
    uri.push(if uri.contains('?') { '&' } else { '?' });
    uri.push_str(name);
    uri.push('=');
    uri.push_str(&percent_encode(value));
}

fn percent_encode(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            encoded.push(char::from(byte));
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

fn reconcile(
    candidates: &[Candidate],
    nix: &OsString,
    timeout: Duration,
    parallelism: usize,
) -> Result<Vec<bool>, String> {
    let next = AtomicUsize::new(0);
    let results = Mutex::new(vec![false; candidates.len()]);
    let errors = Mutex::new(Vec::new());
    let workers = parallelism.min(candidates.len()).max(1);

    thread::scope(|scope| {
        for _ in 0..workers {
            scope.spawn(|| loop {
                let index = next.fetch_add(1, Ordering::Relaxed);
                let Some(candidate) = candidates.get(index) else {
                    break;
                };
                let healthy = match candidate.mode {
                    Mode::Always => true,
                    Mode::Probe => match probe(nix, &candidate.probe_uri, timeout) {
                        Ok(true) => true,
                        Ok(false) => {
                            eprintln!("nix-dynamic-machines: unavailable: {}", candidate.probe_uri);
                            false
                        }
                        Err(error) => {
                            errors.lock().expect("errors lock poisoned").push(format!(
                                "cannot execute probe for {}: {error}",
                                candidate.probe_uri
                            ));
                            false
                        }
                    },
                };
                results.lock().expect("results lock poisoned")[index] = healthy;
            });
        }
    });

    let errors = errors.into_inner().expect("errors lock poisoned");
    if !errors.is_empty() {
        return Err(errors.join("; "));
    }
    Ok(results.into_inner().expect("results lock poisoned"))
}

fn probe(nix: &OsString, uri: &str, timeout: Duration) -> io::Result<bool> {
    let mut command = Command::new(nix);
    command
        .args(["store", "ping", "--store", uri])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(unix)]
    command.process_group(0);

    let mut child = command.spawn()?;
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status.success()),
            Ok(None) => {}
            Err(error) => {
                terminate_process_group(&mut child);
                return Err(error);
            }
        }
        if Instant::now() >= deadline {
            terminate_process_group(&mut child);
            return Ok(false);
        }
        thread::sleep(Duration::from_millis(20).min(timeout));
    }
}

#[cfg(unix)]
fn terminate_process_group(child: &mut Child) {
    unsafe extern "C" {
        fn kill(pid: i32, signal: i32) -> i32;
    }

    let process_group = -(child.id() as i32);
    // SAFETY: The child was placed in a new process group whose ID is its PID.
    // Negative PID targets only that group. Failure is harmless and is followed
    // by Child::kill as a direct-process fallback.
    unsafe {
        kill(process_group, 15);
    }
    // Do not reap the leader during the grace period: its PID keeps the group
    // identity reserved even if it exits before a descendant handles SIGTERM.
    thread::sleep(Duration::from_millis(200));
    // SAFETY: Same process-group argument as above; SIGKILL ensures descendants
    // such as ssh do not survive a timed-out nix process.
    unsafe {
        kill(process_group, 9);
    }
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(not(unix))]
fn terminate_process_group(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

fn render(candidates: &[Candidate], healthy: &[bool]) -> String {
    let lines: Vec<_> = candidates
        .iter()
        .zip(healthy)
        .filter(|(_, healthy)| **healthy)
        .map(|(candidate, _)| candidate.machine_line.as_str())
        .collect();
    if lines.is_empty() {
        String::new()
    } else {
        lines.join("\n") + "\n"
    }
}

fn atomic_write_if_changed(path: &Path, contents: &[u8]) -> io::Result<bool> {
    if fs::read(path).ok().as_deref() == Some(contents) {
        return Ok(false);
    }
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("machines");
    let temporary = parent.join(format!(".{file_name}.{}.tmp", std::process::id()));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o644);
    let result = (|| {
        let mut file = options.open(&temporary)?;
        file.write_all(contents)?;
        file.sync_all()?;
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result.map(|()| true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicU64;

    static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);

    fn temp_dir() -> PathBuf {
        let path = env::temp_dir().join(format!(
            "nix-dynamic-machines-test-{}-{}",
            std::process::id(),
            NEXT_TEMP.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        path
    }

    #[test]
    fn parses_modes_and_preserves_machine_lines() {
        let candidates = parse_candidates(
            "# builders\nprobe ssh-ng://nix@ward x86_64-linux /key 8 10 kvm,big-parallel\n\
             always ssh-ng://root@local x86_64-linux - 4 20\n",
        )
        .unwrap();
        assert_eq!(candidates.len(), 2);
        assert_eq!(candidates[0].mode, Mode::Probe);
        assert_eq!(candidates[1].mode, Mode::Always);
        assert_eq!(
            render(&candidates, &[false, true]),
            "ssh-ng://root@local x86_64-linux - 4 20\n"
        );
    }

    #[test]
    fn probe_uri_includes_machine_credentials() {
        let candidate = parse_candidate(
            "probe ssh-ng://nix@ward x86_64-linux /persist/key 8 10 - - c3NoK2tleT0=",
        )
        .unwrap();
        assert_eq!(
            candidate.probe_uri,
            "ssh-ng://nix@ward?ssh-key=%2Fpersist%2Fkey&base64-ssh-public-host-key=c3NoK2tleT0%3D"
        );
    }

    #[test]
    fn invalid_input_is_rejected() {
        assert!(parse_candidate("sometimes ssh://host").is_err());
        assert!(parse_candidate("probe").is_err());
        assert!(parse_candidate("probe a b c d e f g h i").is_err());
        for line in [
            "always ssh-ng://docker x86_64-linux - not-a-number 20",
            "always ssh://host - - 4294967296",
            "always ssh://host - - 0",
            "always ssh://host - - 1 NaN",
            "always ssh://host - - 1 -1",
            "always ssh://host - - 1 1 - - invalid!",
            "always @/etc/nix/machines",
            "always ssh://one;ssh://two",
            "always ssh://",
        ] {
            assert!(parse_candidate(line).is_err(), "accepted {line}");
        }
    }

    #[test]
    fn always_never_executes_a_probe() {
        let candidates = parse_candidates("always ssh-ng://docker x86_64-linux - 4 20").unwrap();
        assert_eq!(
            reconcile(
                &candidates,
                &OsString::from("/nonexistent/nix"),
                Duration::from_millis(10),
                2
            )
            .unwrap(),
            vec![true]
        );
    }

    #[test]
    fn local_errors_and_invalid_input_preserve_output() {
        let directory = temp_dir();
        let input = directory.join("candidates");
        let output = directory.join("machines");
        fs::write(&output, "previous\n").unwrap();
        for source in ["probe ssh-ng://host", "always ssh-ng://host - - invalid"] {
            fs::write(&input, source).unwrap();
            assert!(run([
                OsString::from("--candidates"),
                input.clone().into_os_string(),
                OsString::from("--output"),
                output.clone().into_os_string(),
                OsString::from("--nix"),
                directory.join("missing-nix").into_os_string(),
            ]
            .into_iter())
            .is_err());
            assert_eq!(fs::read_to_string(&output).unwrap(), "previous\n");
        }
        fs::remove_dir_all(directory).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn timeout_kills_descendants_after_leader_exits() {
        let directory = temp_dir();
        let marker = directory.join("survived");
        let descendant = executable(
            &directory,
            "descendant",
            &format!(
                "trap '' TERM\nsleep 1\nprintf survived > '{}'",
                marker.display()
            ),
        );
        let parent = executable(
            &directory,
            "parent",
            &format!("'{}' &\nwait", Path::new(&descendant).display()),
        );
        assert!(!probe(&parent, "ssh-ng://example", Duration::from_millis(200)).unwrap());
        thread::sleep(Duration::from_millis(1100));
        assert!(!marker.exists(), "descendant survived timeout cleanup");
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn atomic_write_skips_unchanged_content() {
        let directory = temp_dir();
        let output = directory.join("machines");
        assert!(atomic_write_if_changed(&output, b"one\n").unwrap());
        assert!(!atomic_write_if_changed(&output, b"one\n").unwrap());
        assert!(atomic_write_if_changed(&output, b"two\n").unwrap());
        assert_eq!(fs::read_to_string(&output).unwrap(), "two\n");
        fs::remove_dir_all(directory).unwrap();
    }

    #[cfg(unix)]
    fn executable(directory: &Path, name: &str, body: &str) -> OsString {
        use std::os::unix::fs::PermissionsExt;

        let path = directory.join(name);
        fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        path.into_os_string()
    }

    #[cfg(unix)]
    #[test]
    fn probes_success_failure_and_timeout() {
        let directory = temp_dir();
        let success = executable(&directory, "success", "exit 0");
        let failure = executable(&directory, "failure", "exit 1");
        let sleeper = executable(&directory, "sleeper", "sleep 10");
        assert!(probe(&success, "ssh-ng://example", Duration::from_secs(1)).unwrap());
        assert!(!probe(&failure, "ssh-ng://example", Duration::from_secs(1)).unwrap());
        let started = Instant::now();
        assert!(!probe(&sleeper, "ssh-ng://example", Duration::from_millis(50)).unwrap());
        assert!(started.elapsed() < Duration::from_secs(2));
        fs::remove_dir_all(directory).unwrap();
    }
}
