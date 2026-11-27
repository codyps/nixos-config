use actions_vm_scaler::{
    api::Api,
    config::read_scale_sets,
    fleet::{serve, Fleet},
    vm::Manager,
};
use anyhow::{ensure, Context, Result};
use std::{path::Path, time::Duration};

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() == 2 && ["--help", "-h"].contains(&args[1].as_str()) {
        println!("Usage: actions-vm-scaler <check|run> /absolute/config.json\nOn NixOS: sudo sys actions-vm-scaler check CONFIG");
        return Ok(());
    }
    ensure!(
        args.len() == 3 && ["check", "run"].contains(&args[1].as_str()),
        "usage: actions-vm-scaler <check|run> CONFIG"
    );
    let configs = read_scale_sets(Path::new(&args[2]))?;
    for config in &configs {
        config
            .check_files()
            .with_context(|| format!("checking scale set {}", config.scale_set))?;
    }
    if args[1] == "check" {
        println!("Configuration and input files validated (no network or VM changes)");
        return Ok(());
    }
    ensure!(cfg!(target_os = "linux"), "VM service requires Linux/KVM");
    ensure!(Path::new("/dev/kvm").exists(), "/dev/kvm is unavailable");
    // Bootstrap media, disks, keys and state must never become world-readable.
    unsafe {
        libc::umask(0o077);
    }
    let first = configs[0].clone();
    if first.github_url.is_empty() {
        let discovery = Api::new(first.clone())?;
        let mut fleets = Vec::with_capacity(configs.len());
        for config in configs {
            fleets.push(Fleet::with_api(config, &discovery).await?);
        }
        let interval = Duration::from_secs(first.discovery_interval_secs);
        let result = tokio::select! {
            result = Fleet::run_all(&mut fleets, &discovery, interval) => result,
            _ = shutdown() => Ok(()),
        };
        Fleet::shutdown_all(&mut fleets).await;
        result
    } else {
        let api = Api::new(first.clone())?;
        let manager = Manager::new(first)?;
        let (stop, receiver) = tokio::sync::oneshot::channel();
        let worker = serve(manager, api, receiver);
        tokio::pin!(worker);
        tokio::select! { _ = &mut worker => return Ok(()), _ = shutdown() => {} }
        let _ = stop.send(());
        worker.await;
        Ok(())
    }
}

async fn shutdown() {
    #[cfg(unix)]
    {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("SIGTERM handler");
        tokio::select! { _ = tokio::signal::ctrl_c() => {}, _ = term.recv() => {} }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}
