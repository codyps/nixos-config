//! The coordinator owns state and publication; probe tasks own their children.
use super::*;
use std::collections::BTreeSet;
use tokio::sync::watch as cancellation;
use tokio::task::JoinSet;
use tokio::time::Instant;

type Completion = (String, io::Result<bool>, Instant, Result<u64, String>);

fn deadlines(
    candidates: &[Candidate],
    state: &State,
    args: &Args,
    force: bool,
    wall: u64,
    now: Instant,
) -> BTreeMap<String, Instant> {
    candidates
        .iter()
        .filter(|c| c.mode == Mode::Probe)
        .map(|c| {
            let remaining = state
                .records
                .get(&c.machine_line)
                .filter(|r| !force && r.fresh(wall, args.policy))
                .map_or(0, |r| {
                    r.checked_at
                        .saturating_add(r.delay(args.policy))
                        .saturating_sub(wall)
                });
            (c.machine_line.clone(), now + Duration::from_secs(remaining))
        })
        .collect()
}

async fn publish(args: &Args, candidates: &[Candidate], state: &State) -> Result<(), String> {
    let args = args.clone();
    let candidates = candidates.to_vec();
    let mut state = state.clone();
    // Await each blocking publication: no concurrent writers or out-of-order snapshots.
    tokio::task::spawn_blocking(move || {
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
        let bytes = serde_json::to_vec_pretty(&state).map_err(|e| e.to_string())?;
        let changed = atomic_write_if_changed(&args.output, contents.as_bytes())
            .map_err(|e| format!("cannot update output: {e}"))?;
        atomic_write_if_changed(&args.state, &bytes)
            .map_err(|e| format!("cannot update state: {e}"))?;
        if changed {
            eprintln!(
                "nix-dynamic-machines: {} of {} candidates enabled (updated)",
                healthy.iter().filter(|h| **h).count(),
                candidates.len()
            );
        }
        Ok(())
    })
    .await
    .map_err(|e| e.to_string())?
}

async fn drain(jobs: &mut JoinSet<Completion>, cancel: &cancellation::Sender<bool>) {
    let _ = cancel.send(true);
    // Never abort probe tasks: each must finish process-group cleanup and reap.
    while jobs.join_next().await.is_some() {}
}

#[cfg(unix)]
pub(super) async fn watch(
    args: &Args,
    mut candidates: Vec<Candidate>,
    mut state: State,
) -> Result<(), String> {
    use tokio::signal::unix::{signal, SignalKind};
    let mut hup = signal(SignalKind::hangup()).map_err(|e| e.to_string())?;
    let mut term = signal(SignalKind::terminate()).map_err(|e| e.to_string())?;
    let mut interrupt = signal(SignalKind::interrupt()).map_err(|e| e.to_string())?;
    let (mut cancel, mut receiver) = cancellation::channel(false);
    let mut jobs = JoinSet::new();
    let mut active = BTreeSet::new();
    let mut due = deadlines(
        &candidates,
        &state,
        args,
        args.force,
        now_seconds()?,
        Instant::now(),
    );
    let result = async {
        publish(args, &candidates, &state).await?;
        loop {
            // Earliest-deadline order prevents starvation when a full queue ages.
            while jobs.len() < args.parallelism {
                let next = due.iter().filter(|(line, _)| !active.contains(*line)).min_by_key(|(_, deadline)| **deadline);
                let Some((line, deadline)) = next else { break };
                if *deadline > Instant::now() { break }
                let line = line.clone();
                let candidate = candidates.iter().find(|c| c.mode == Mode::Probe && c.machine_line == line).expect("scheduled candidate exists").clone();
                active.insert(line.clone());
                let nix = args.nix.clone();
                let timeout = args.timeout;
                let receiver = receiver.clone();
                jobs.spawn(async move {
                    let result = probe_async(&nix, &candidate.probe_uri, timeout, receiver).await;
                    (line, result, Instant::now(), now_seconds())
                });
            }
            // With all slots occupied, only completion/signals can make progress.
            // With no probe entries, wait solely for a signal (no idle tick).
            let next = if jobs.len() < args.parallelism {
                due.iter().filter(|(line, _)| !active.contains(*line)).map(|(_, deadline)| *deadline).min()
            } else { None };
            tokio::select! {
                biased;
                _ = term.recv() => break,
                _ = interrupt.recv() => break,
                _ = hup.recv() => {
                    let path = args.candidates.clone();
                    let loaded = tokio::task::spawn_blocking(move || {
                        let source = fs::read_to_string(path).map_err(|e| e.to_string())?;
                        parse_candidates(&source)
                    }).await.map_err(|e| e.to_string())?;
                    match loaded {
                        Err(error) => eprintln!("nix-dynamic-machines: reload rejected; keeping current configuration: {error}"),
                        Ok(updated) => {
                            drain(&mut jobs, &cancel).await;
                            (cancel, receiver) = cancellation::channel(false);
                            active.clear();
                            candidates = updated;
                            state.records.retain(|line, _| candidates.iter().any(|c| c.mode == Mode::Probe && c.machine_line == *line));
                            due = deadlines(&candidates, &state, args, true, now_seconds()?, Instant::now());
                            publish(args, &candidates, &state).await?;
                            eprintln!("nix-dynamic-machines: reloaded; refreshing probe entries");
                        }
                    }
                }
                completed = jobs.join_next(), if !jobs.is_empty() => {
                    let (line, result, finished, checked_at) = completed.expect("nonempty task set").map_err(|e| e.to_string())?;
                    active.remove(&line);
                    let delay = match result {
                        Ok(healthy) => {
                            let failures = if healthy { 0 } else { state.records.get(&line).map_or(1, |r| r.failures.saturating_add(1)) };
                            let record = ProbeRecord { checked_at: checked_at?, failures };
                            let delay = record.delay(args.policy);
                            state.records.insert(line.clone(), record);
                            publish(args, &candidates, &state).await?;
                            delay
                        }
                        Err(error) => {
                            eprintln!("nix-dynamic-machines: local probe error for {line}; preserving membership: {error}");
                            args.policy.retry
                        }
                    };
                    due.insert(line, finished + Duration::from_secs(delay));
                }
                _ = async {
                    if let Some(deadline) = next { tokio::time::sleep_until(deadline).await }
                    else { std::future::pending::<()>().await }
                } => {}
            }
        }
        Ok(())
    }.await;
    drain(&mut jobs, &cancel).await;
    // Cancelled probes are not health observations. All completed observations
    // were published serially; flush the last accepted state on orderly shutdown.
    if result.is_ok() {
        publish(args, &candidates, &state).await?;
    }
    result
}

#[cfg(not(unix))]
pub(super) async fn watch(_: &Args, _: Vec<Candidate>, _: State) -> Result<(), String> {
    Err("--watch requires Unix signal support".to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(start_paused = true)]
    async fn deadlines_reuse_cache_exclude_always_and_force_only_probes() {
        let args = parse_args(
            ["--candidates", "candidates", "--output", "machines"]
                .into_iter()
                .map(OsString::from),
        )
        .unwrap()
        .unwrap();
        let candidates = parse_candidates(
            "always ssh://docker\nprobe ssh://healthy\nprobe ssh://offline\nprobe ssh://new",
        )
        .unwrap();
        let state = State {
            version: 1,
            nix: PathBuf::from("nix"),
            records: BTreeMap::from([
                (
                    "ssh://healthy".to_owned(),
                    ProbeRecord {
                        checked_at: 100,
                        failures: 0,
                    },
                ),
                (
                    "ssh://offline".to_owned(),
                    ProbeRecord {
                        checked_at: 110,
                        failures: 2,
                    },
                ),
            ]),
        };
        let now = Instant::now();
        let due = deadlines(&candidates, &state, &args, false, 120, now);
        assert_eq!(due.len(), 3);
        assert_eq!(due["ssh://new"], now);
        assert_eq!(due["ssh://healthy"], now + Duration::from_secs(40));
        assert_eq!(due["ssh://offline"], now + Duration::from_secs(20));
        tokio::time::sleep_until(due["ssh://offline"]).await;
        assert_eq!(Instant::now(), now + Duration::from_secs(20));
        assert!(deadlines(&candidates, &state, &args, true, 120, now)
            .values()
            .all(|d| *d == now));
        assert!(deadlines(&candidates, &state, &args, false, 99, now)
            .values()
            .all(|d| *d == now));
    }
}
