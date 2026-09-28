//! Installation-wide discovery and supervision. Repository API failures remain
//! local to that repository; VM slots are shared across all listeners.
use crate::{
    api::{Api, Repository},
    config::Config,
    controller,
    pool::Pool,
    vm::Manager,
};
use anyhow::{ensure, Result};
use std::{collections::BTreeMap, fs, os::unix::fs::DirBuilderExt, sync::Arc, time::Duration};
use tokio::{sync::oneshot, task::JoinHandle};

struct Worker {
    repository: Repository,
    stop: Option<oneshot::Sender<()>>,
    task: JoinHandle<()>,
}

pub struct Fleet {
    config: Config,
    api: Api,
    pool: Arc<Pool>,
    workers: BTreeMap<u64, Worker>,
    _guard: Manager,
}

/// Only complete successful discovery snapshots may be passed here.
pub fn eligible(repositories: Vec<Repository>) -> BTreeMap<u64, Repository> {
    repositories
        .into_iter()
        .filter(|r| !r.archived && !r.disabled)
        .map(|r| (r.id, r))
        .collect()
}

impl Fleet {
    #[cfg(test)]
    pub(crate) fn set_test_api(&mut self, api: Api) {
        self.api = api;
    }
    #[cfg(test)]
    pub(crate) fn repository_ids(&self) -> Vec<u64> {
        self.workers.keys().copied().collect()
    }

    pub async fn new(config: Config) -> Result<Self> {
        ensure!(
            config.github_url.is_empty(),
            "fleet mode requires installation discovery"
        );
        let guard = Manager::new(config.clone())?;
        let pool = Pool::new(config.vm.taps.len());
        let directory = config.state_dir.join("repositories");
        if !directory.exists() {
            fs::DirBuilder::new().mode(0o700).create(&directory)?;
        }
        ensure!(
            fs::symlink_metadata(&directory)?.is_dir(),
            "repository state must be a real directory"
        );
        // After a process/host crash, remove stale local disks even for a repo
        // that no longer grants access. Keep name-only registration intents.
        for entry in fs::read_dir(&directory)? {
            let entry = entry?;
            ensure!(
                entry.file_type()?.is_dir(),
                "unexpected repository state entry"
            );
            let name = entry.file_name().to_string_lossy().into_owned();
            let id: u64 = name.parse()?;
            ensure!(
                id > 0 && name == id.to_string(),
                "invalid repository state ID"
            );
            // A crash between directory/lock creation and identity publication
            // cannot have created a VM. Let discovery finish initialization.
            if !entry.path().join("identity.json").exists() {
                for partial in fs::read_dir(entry.path())? {
                    let partial = partial?;
                    ensure!(
                        partial.file_name() == "lock" && partial.file_type()?.is_file(),
                        "unidentified repository state contains unexpected files"
                    );
                }
                continue;
            }
            let scoped = Manager::stored_config(&config, entry.path(), id)?;
            let mut manager = Manager::with_pool(scoped, pool.clone())?;
            manager.discard_local().await?;
        }
        let api = Api::new(config.clone())?;
        Ok(Self {
            api,
            config,
            pool,
            workers: BTreeMap::new(),
            _guard: guard,
        })
    }

    pub(crate) async fn reconcile(&mut self, repositories: Vec<Repository>) -> Result<()> {
        let desired = eligible(repositories);
        let removed: Vec<_> = self
            .workers
            .iter()
            .filter(|(id, worker)| {
                desired.get(id) != Some(&worker.repository) || worker.task.is_finished()
            })
            .map(|(id, _)| *id)
            .collect();
        for id in &removed {
            let worker = self.workers.get_mut(id).unwrap();
            if let Some(stop) = worker.stop.take() {
                let _ = stop.send(());
            }
        }
        for id in removed {
            // Keep handles owned by Fleet while awaiting: cancellation must not
            // detach a worker from the shutdown path.
            let worker = self.workers.get_mut(&id).unwrap();
            if let Err(error) = (&mut worker.task).await {
                eprintln!(
                    "repository worker {} exited: {error}",
                    worker.repository.full_name
                );
            }
            self.workers.remove(&id);
        }
        for (id, repo) in desired {
            if self.workers.contains_key(&id) {
                continue;
            }
            let mut scoped = self.config.clone();
            scoped.github_url = format!("https://github.com/{}", repo.full_name);
            scoped.repository_id = Some(id);
            scoped.state_dir = self
                .config
                .state_dir
                .join("repositories")
                .join(id.to_string());
            let manager = match Manager::with_pool(scoped, self.pool.clone()) {
                Ok(manager) => manager,
                Err(error) => {
                    eprintln!("repository {} state unavailable: {error:#}", repo.full_name);
                    continue;
                }
            };
            let (stop, receiver) = oneshot::channel();
            eprintln!(
                "serving repository {} with scale-set label {}",
                repo.full_name, self.config.scale_set
            );
            let api = self.api.scoped(manager.config.clone());
            let task = tokio::spawn(serve(manager, api, receiver));
            self.workers.insert(
                id,
                Worker {
                    repository: repo,
                    stop: Some(stop),
                    task,
                },
            );
        }
        Ok(())
    }

    pub async fn run(&mut self) -> Result<()> {
        loop {
            match self.api.repositories().await {
                Ok(repositories) => self.reconcile(repositories).await?,
                // A partial/failed scan is not evidence of revoked access.
                Err(error) => {
                    eprintln!("repository discovery failed; keeping existing listeners: {error:#}")
                }
            }
            tokio::time::sleep(Duration::from_secs(self.config.discovery_interval_secs)).await;
        }
    }

    pub async fn shutdown(&mut self) {
        for worker in self.workers.values_mut() {
            if let Some(stop) = worker.stop.take() {
                let _ = stop.send(());
            }
        }
        // All workers clean up concurrently, bounded individually below.
        for (_, worker) in std::mem::take(&mut self.workers) {
            let _ = worker.task.await;
        }
    }
}

impl Drop for Fleet {
    fn drop(&mut self) {
        for worker in self.workers.values() {
            worker.task.abort();
        }
    }
}

pub async fn serve(mut manager: Manager, mut api: Api, mut stop: oneshot::Receiver<()>) {
    let mut backoff = 2;
    loop {
        api = api.scoped(manager.config.clone());
        let stopped = tokio::select! {
            _ = &mut stop => true,
            result = async {
                api.ensure_scale_set().await?;
                controller::listen(&mut api, &mut manager).await
            } => {
                if let Err(error) = result { eprintln!("repository {} listener failed: {error:#}", manager.config.github_url); }
                false
            }
        };
        manager.pool.cancel(&manager.owner);
        manager.stop_all().await;
        let cleaned = tokio::time::timeout(Duration::from_secs(25), async {
            let reap = if api.scale_set_id > 0 {
                manager.reap(&mut api).await
            } else {
                Ok(())
            };
            let close = api.close_session().await;
            reap.and(close)
        })
        .await;
        if !matches!(cleaned, Ok(Ok(()))) {
            eprintln!(
                "repository {} remote cleanup pending",
                manager.config.github_url
            );
        }
        if let Err(error) = manager.discard_local().await {
            eprintln!("local cleanup failed: {error:#}");
            return;
        }
        if stopped {
            return;
        }
        tokio::select! {
            _ = &mut stop => return,
            _ = tokio::time::sleep(Duration::from_secs(backoff)) => {},
        }
        backoff = (backoff * 2).min(60);
    }
}
