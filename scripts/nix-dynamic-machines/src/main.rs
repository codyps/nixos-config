use std::collections::BTreeMap;
use std::env;
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitCode, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use wait_timeout::ChildExt;

#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
#[cfg(unix)]
use std::os::unix::process::CommandExt;

const USAGE: &str = "Usage: nix-dynamic-machines --candidates PATH --output PATH [OPTIONS]

Options:
  --nix PATH              nix executable to use (default: nix)
  --timeout SECONDS       timeout for each probe (default: 3)
  --parallelism COUNT     maximum concurrent probes (default: 8)
  --state PATH            persistent probe cache (default: OUTPUT.state.json)
  --healthy-interval SEC  recheck healthy builders after SEC (default: 60)
  --retry-interval SEC    first retry after failure (default: 15)
  --max-retry-interval SEC  maximum retry delay (default: 120)
  --force                 probe now, ignoring cached deadlines (never probes always)
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
    state: PathBuf,
    policy: Policy,
    force: bool,
}

#[derive(Clone, Copy, Debug)]
struct Policy {
    healthy: u64,
    retry: u64,
    max_retry: u64,
}

impl Default for Policy {
    fn default() -> Self {
        Self {
            healthy: 60,
            retry: 15,
            max_retry: 120,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
struct ProbeRecord {
    checked_at: u64,
    failures: u32,
}

impl ProbeRecord {
    fn delay(&self, policy: Policy) -> u64 {
        if self.failures == 0 {
            policy.healthy
        } else {
            policy
                .retry
                .saturating_mul(1u64 << (self.failures - 1).min(63))
                .min(policy.max_retry)
        }
    }

    fn fresh(&self, now: u64, policy: Policy) -> bool {
        // A clock rollback invalidates the observation instead of extending it.
        now >= self.checked_at && now < self.checked_at.saturating_add(self.delay(policy))
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct State {
    version: u32,
    nix: PathBuf,
    records: BTreeMap<String, ProbeRecord>,
}

fn now_seconds() -> Result<u64, String> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|time| time.as_secs())
        .map_err(|e| format!("invalid system clock: {e}"))
}

fn appended(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_os_string();
    name.push(suffix);
    name.into()
}

fn parent_dir(path: &Path) -> &Path {
    path.parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."))
}

fn load_state(path: &Path, nix: &OsString) -> Result<State, String> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            return Ok(State {
                version: 1,
                nix: PathBuf::from(nix),
                records: BTreeMap::new(),
            })
        }
        Err(e) => return Err(format!("cannot read state {}: {e}", path.display())),
    };
    let mut state: State = serde_json::from_slice(&bytes)
        .map_err(|e| format!("invalid state {}: {e}", path.display()))?;
    if state.version != 1 {
        return Err(format!("unsupported state version {}", state.version));
    }
    if state.nix != Path::new(nix) {
        state.nix = PathBuf::from(nix);
        state.records.clear();
    }
    Ok(state)
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
    fs::create_dir_all(parent_dir(&args.output)).map_err(|e| e.to_string())?;
    fs::create_dir_all(parent_dir(&args.state)).map_err(|e| e.to_string())?;
    let lock_path = appended(&args.output, ".lock");
    let mut paths = Vec::new();
    for path in [&args.candidates, &args.output, &args.state, &lock_path] {
        let resolved = if path.exists() {
            fs::canonicalize(path)
        } else {
            fs::canonicalize(parent_dir(path))
                .map(|parent| parent.join(path.file_name().unwrap_or_default()))
        }
        .map_err(|e| format!("cannot resolve {}: {e}", path.display()))?;
        if paths.contains(&resolved) {
            return Err("candidates, output, state, and lock paths must be distinct".to_owned());
        }
        paths.push(resolved);
    }
    // Hold a separate, stable lock across reads, probes, and both publications.
    // Concurrent timer/manual runs then consume the latest cache rather than
    // probing twice or publishing an older observation after a newer one.
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&lock_path)
        .map_err(|e| format!("cannot open lock: {e}"))?;
    lock.lock()
        .map_err(|e| format!("cannot lock output: {e}"))?;
    let source = fs::read_to_string(&args.candidates)
        .map_err(|e| format!("cannot read {}: {e}", args.candidates.display()))?;
    let candidates = parse_candidates(&source)?;
    let mut state = load_state(&args.state, &args.nix)?;
    let now = now_seconds()?;
    let due: Vec<_> = candidates
        .iter()
        .filter(|candidate| {
            candidate.mode == Mode::Probe
                && (args.force
                    || !state
                        .records
                        .get(&candidate.machine_line)
                        .is_some_and(|record| record.fresh(now, args.policy)))
        })
        .cloned()
        .collect();
    let results = reconcile(&due, &args.nix, args.timeout, args.parallelism)?;
    let checked_at = now_seconds()?;
    for (candidate, healthy) in due.iter().zip(results) {
        let failures = if healthy {
            0
        } else {
            state
                .records
                .get(&candidate.machine_line)
                .map_or(1, |r| r.failures.saturating_add(1))
        };
        state.records.insert(
            candidate.machine_line.clone(),
            ProbeRecord {
                checked_at,
                failures,
            },
        );
    }
    state.records.retain(|line, _| {
        candidates
            .iter()
            .any(|c| c.mode == Mode::Probe && c.machine_line == *line)
    });
    let healthy: Vec<_> = candidates
        .iter()
        .map(|c| {
            c.mode == Mode::Always
                || state
                    .records
                    .get(&c.machine_line)
                    .is_some_and(|r| r.failures == 0)
        })
        .collect();
    let contents = render(&candidates, &healthy);
    let state_bytes = serde_json::to_vec_pretty(&state).map_err(|e| e.to_string())?;
    let changed = atomic_write_if_changed(&args.output, contents.as_bytes())
        .map_err(|e| format!("cannot update {}: {e}", args.output.display()))?;
    atomic_write_if_changed(&args.state, &state_bytes)
        .map_err(|e| format!("cannot update state {}: {e}", args.state.display()))?;
    eprintln!(
        "nix-dynamic-machines: {} of {} candidates enabled{}; {} probed",
        healthy.iter().filter(|healthy| **healthy).count(),
        candidates.len(),
        if changed {
            " (updated)"
        } else {
            " (unchanged)"
        },
        due.len()
    );
    Ok(())
}

fn parse_args(mut args: impl Iterator<Item = OsString>) -> Result<Option<Args>, String> {
    let mut candidates = None;
    let mut output = None;
    let mut nix = OsString::from("nix");
    let mut timeout = Duration::from_secs(3);
    let mut parallelism = 8;
    let mut state = None;
    let mut policy = Policy::default();
    let mut force = false;

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
            "--state" => state = Some(PathBuf::from(value(&mut args, text)?)),
            "--force" => force = true,
            "--healthy-interval" | "--retry-interval" | "--max-retry-interval" => {
                let seconds = value(&mut args, text)?
                    .to_str()
                    .and_then(|s| s.parse::<u64>().ok())
                    .filter(|n| (1..=86400).contains(n))
                    .ok_or_else(|| format!("{text} must be an integer from 1 to 86400"))?;
                match text {
                    "--healthy-interval" => policy.healthy = seconds,
                    "--retry-interval" => policy.retry = seconds,
                    _ => policy.max_retry = seconds,
                }
            }
            "--timeout" => {
                let raw = value(&mut args, text)?;
                let seconds = raw
                    .to_str()
                    .and_then(|s| s.parse::<f64>().ok())
                    .filter(|n| n.is_finite() && *n >= 0.001 && *n <= 86400.0)
                    .ok_or_else(|| {
                        "--timeout must be between 0.001 and 86400 seconds".to_owned()
                    })?;
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

    let candidates = candidates.ok_or_else(|| "--candidates is required".to_owned())?;
    let output = output.ok_or_else(|| "--output is required".to_owned())?;
    let state = state.unwrap_or_else(|| appended(&output, ".state.json"));
    if policy.retry > policy.max_retry {
        return Err("--retry-interval must not exceed --max-retry-interval".to_owned());
    }
    if candidates == output || candidates == state || output == state {
        return Err("candidates, output, and state paths must be distinct".to_owned());
    }
    Ok(Some(Args {
        candidates,
        output,
        nix,
        timeout,
        parallelism,
        state,
        policy,
        force,
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
    if candidates.is_empty() {
        return Ok(Vec::new());
    }
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
    // SIGCHLD-backed waiting on Unix; no periodic try_wait wakeups.
    // Recheck once at the deadline: signal delivery can lag process exit, and
    // an already-completed child must not be classified as a timeout.
    let result = child.wait_timeout(timeout).and_then(|status| match status {
        Some(status) => Ok(Some(status)),
        None => child.try_wait(),
    });
    match result {
        Ok(Some(status)) => {
            if !status.success() {
                eprintln!("nix-dynamic-machines: probe exited with {status}: {uri}");
            }
            Ok(status.success())
        }
        Ok(None) => {
            eprintln!("nix-dynamic-machines: probe timed out after {timeout:?}: {uri}");
            terminate_process_group(&mut child);
            Ok(false)
        }
        Err(error) => {
            terminate_process_group(&mut child);
            Err(error)
        }
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
    let parent = parent_dir(path);
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
    use std::time::Instant;

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

    #[test]
    fn retry_delays_are_capped_and_clock_rollback_expires_cache() {
        let policy = Policy::default();
        for (failures, delay) in [
            (0, 60),
            (1, 15),
            (2, 30),
            (3, 60),
            (4, 120),
            (u32::MAX, 120),
        ] {
            let record = ProbeRecord {
                checked_at: 1000,
                failures,
            };
            assert_eq!(record.delay(policy), delay);
            assert!(record.fresh(1000 + delay - 1, policy));
            assert!(!record.fresh(1000 + delay, policy));
            assert!(!record.fresh(999, policy));
        }
    }

    fn invoke(directory: &Path, nix: &OsString, force: bool) -> Result<(), String> {
        let mut args = vec![
            OsString::from("--candidates"),
            directory.join("candidates").into_os_string(),
            OsString::from("--output"),
            directory.join("machines").into_os_string(),
            OsString::from("--nix"),
            nix.clone(),
        ];
        if force {
            args.push(OsString::from("--force"));
        }
        run(args.into_iter())
    }

    #[cfg(unix)]
    #[test]
    fn cache_skips_probes_force_refreshes_and_changes_invalidate() {
        let directory = temp_dir();
        let calls = directory.join("calls");
        let nix = executable(
            &directory,
            "nix",
            &format!("printf x >> '{}'\nexit 0", calls.display()),
        );
        let input = directory.join("candidates");
        let output = directory.join("machines");
        let state_path = appended(&output, ".state.json");
        fs::write(&input, "always ssh-ng://docker\nprobe ssh-ng://remote").unwrap();
        invoke(&directory, &nix, false).unwrap();
        let state_bytes = fs::read(&state_path).unwrap();
        invoke(&directory, &nix, false).unwrap();
        assert_eq!(fs::read(&calls).unwrap(), b"x");
        assert_eq!(fs::read(&state_path).unwrap(), state_bytes);
        assert_eq!(
            fs::read_to_string(&output).unwrap(),
            "ssh-ng://docker\nssh-ng://remote\n"
        );
        invoke(&directory, &nix, true).unwrap();
        assert_eq!(fs::read(&calls).unwrap(), b"xx");
        fs::write(
            &input,
            "always ssh-ng://docker\nprobe ssh-ng://remote - /new-key",
        )
        .unwrap();
        invoke(&directory, &nix, false).unwrap();
        assert_eq!(fs::read(&calls).unwrap(), b"xxx");
        let state = load_state(&state_path, &nix).unwrap();
        assert_eq!(state.records.len(), 1);
        assert!(state.records.contains_key("ssh-ng://remote - /new-key"));
        fs::write(&input, "always ssh-ng://docker").unwrap();
        invoke(
            &directory,
            &directory.join("nonexistent-nix").into_os_string(),
            true,
        )
        .unwrap();
        assert_eq!(fs::read(&calls).unwrap(), b"xxx");
        assert_eq!(fs::read_to_string(&output).unwrap(), "ssh-ng://docker\n");
        fs::remove_dir_all(directory).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn failed_probes_back_off_and_success_resets_failures() {
        let directory = temp_dir();
        let calls = directory.join("calls");
        let recovered = directory.join("recovered");
        let nix = executable(
            &directory,
            "nix",
            &format!(
                "printf x >> '{}'\ntest -f '{}'",
                calls.display(),
                recovered.display()
            ),
        );
        fs::write(directory.join("candidates"), "probe ssh-ng://remote").unwrap();
        let state_path = directory.join("machines.state.json");
        for failures in 1..=5 {
            invoke(&directory, &nix, false).unwrap();
            let mut state = load_state(&state_path, &nix).unwrap();
            assert_eq!(state.records["ssh-ng://remote"].failures, failures);
            invoke(&directory, &nix, false).unwrap();
            assert_eq!(fs::read(&calls).unwrap().len(), failures as usize);
            state.records.get_mut("ssh-ng://remote").unwrap().checked_at = 0;
            fs::write(&state_path, serde_json::to_vec(&state).unwrap()).unwrap();
        }
        fs::write(&recovered, "ready").unwrap();
        invoke(&directory, &nix, false).unwrap();
        let state = load_state(&state_path, &nix).unwrap();
        assert_eq!(state.records["ssh-ng://remote"].failures, 0);
        assert_eq!(
            fs::read_to_string(directory.join("machines")).unwrap(),
            "ssh-ng://remote\n"
        );
        fs::remove_dir_all(directory).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn overlapping_runs_share_the_latest_result() {
        let directory = temp_dir();
        let calls = directory.join("calls");
        let nix = executable(
            &directory,
            "nix",
            &format!("printf x >> '{}'\nsleep 0.1\nexit 0", calls.display()),
        );
        fs::write(directory.join("candidates"), "probe ssh-ng://remote").unwrap();
        thread::scope(|scope| {
            let first = scope.spawn(|| invoke(&directory, &nix, false));
            let second = scope.spawn(|| invoke(&directory, &nix, false));
            first.join().unwrap().unwrap();
            second.join().unwrap().unwrap();
        });
        assert_eq!(fs::read(&calls).unwrap(), b"x");
        fs::remove_dir_all(directory).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn local_error_and_corrupt_cache_preserve_both_files() {
        let directory = temp_dir();
        let nix = executable(&directory, "nix", "exit 0");
        fs::write(directory.join("candidates"), "probe ssh-ng://remote").unwrap();
        invoke(&directory, &nix, false).unwrap();
        let state_path = directory.join("machines.state.json");
        let bytes = fs::read(&state_path).unwrap();
        assert!(invoke(
            &directory,
            &directory.join("missing").into_os_string(),
            true
        )
        .is_err());
        assert_eq!(fs::read(&state_path).unwrap(), bytes);
        fs::write(&state_path, "corrupt").unwrap();
        assert!(invoke(&directory, &nix, false).is_err());
        assert_eq!(fs::read_to_string(&state_path).unwrap(), "corrupt");
        assert_eq!(
            fs::read_to_string(directory.join("machines")).unwrap(),
            "ssh-ng://remote\n"
        );
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
        // These assertions check exit status, not process-startup latency in a
        // loaded package sandbox. The separate sleeper checks the short deadline.
        assert!(probe(&success, "ssh-ng://example", Duration::from_secs(5)).unwrap());
        assert!(!probe(&failure, "ssh-ng://example", Duration::from_secs(5)).unwrap());
        let started = Instant::now();
        assert!(!probe(&sleeper, "ssh-ng://example", Duration::from_millis(50)).unwrap());
        assert!(started.elapsed() < Duration::from_secs(2));
        fs::remove_dir_all(directory).unwrap();
    }
}
