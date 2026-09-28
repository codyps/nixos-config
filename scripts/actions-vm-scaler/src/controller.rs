use crate::{
    api::{Api, Message},
    vm::Manager,
};
use anyhow::Result;
use std::time::Duration;

pub fn target(assigned: usize, capacity: usize) -> usize {
    assigned.min(capacity)
}

pub async fn apply(
    api: &mut Api,
    manager: &mut Manager,
    message: &Message,
    assigned: &mut usize,
) -> Result<()> {
    let jobs = message.jobs()?;
    // Acquiring already acquired jobs is safe on redelivery. GitHub enforces the
    // maximum capacity sent with each poll; we never exceed the local slot limit.
    api.acquire(
        jobs.iter()
            .filter(|j| j.message_type == "JobAvailable")
            .map(|j| j.runner_request_id)
            .collect(),
    )
    .await?;
    for job in &jobs {
        match job.message_type.as_str() {
            "JobStarted" => manager.mark_started(&job.runner_name),
            "JobCompleted" => manager.mark_completed(&job.runner_name),
            _ => {}
        }
    }
    if let Some(stats) = &message.statistics {
        *assigned = stats.total_assigned_jobs;
    }
    converge(api, manager, *assigned).await
}

pub async fn converge(api: &mut Api, manager: &mut Manager, assigned: usize) -> Result<()> {
    manager.reap(api).await?;
    let desired = target(assigned, manager.config.vm.taps.len());
    while manager.count() < desired {
        if !manager.spawn(api).await? {
            break;
        }
    }
    if manager.count() >= desired {
        manager.pool.cancel(&manager.owner);
    }
    // Never kill a possibly assigned runner based only on stale statistics.
    // Completion, QEMU exit and deadlines reclaim excess/abandoned runners.
    Ok(())
}

pub async fn listen(api: &mut Api, manager: &mut Manager) -> Result<()> {
    manager.recover(api).await?;
    api.open_session(&manager.owner).await?;
    let mut assigned = api.session.as_ref().unwrap().statistics.total_assigned_jobs;
    let mut changed = manager.pool.subscribe();
    let mut last = 0;
    let mut pending = None;
    let mut backoff = 2u64;
    loop {
        let result: Result<()> = async {
            // Keep existing guests on transient API failures and replay the same
            // message until all effects and acknowledgment have succeeded.
            converge(api, manager, assigned).await?;
            if pending.is_none() {
                tokio::select! {
                    result = api.poll(last, manager.config.vm.taps.len()) => { pending = result?; }
                    _ = changed.changed() => { return Ok(()); }
                }
            }
            if let Some(message) = &pending {
                apply(api, manager, message, &mut assigned).await?;
                api.acknowledge(message.message_id).await?;
                last = message.message_id;
                pending = None;
            }
            Ok(())
        }
        .await;
        match result {
            Ok(()) => {
                backoff = 2;
            }
            Err(error) => {
                manager.pool.cancel(&manager.owner);
                if error.is::<crate::api::SessionLost>() {
                    return Err(error);
                }
                eprintln!("reconciliation failed; retrying in {backoff}s: {error:#}");
                // Local deadlines are enforced even when GitHub is unavailable.
                // reap kills children before attempting remote deletion.
                if let Err(error) = manager.reap(api).await {
                    eprintln!("cleanup pending: {error:#}");
                }
                tokio::time::sleep(Duration::from_secs(backoff)).await;
                backoff = (backoff * 2).min(60);
            }
        }
    }
}
