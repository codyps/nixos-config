use crate::{
    api::Api,
    config::Config,
    pool::{Lease, Pool},
};
use anyhow::{ensure, Context, Result};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::Write,
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    process::Stdio,
    time::{Duration, Instant},
};
use tokio::process::{Child, Command};
use uuid::Uuid;

#[derive(Serialize, Deserialize)]
struct Identity {
    controller: Uuid,
    github_url: String,
    scale_set: String,
    #[serde(default)]
    repository_id: Option<u64>,
    #[serde(default)]
    installation_id: u64,
}

pub struct Vm {
    _lease: Lease,
    pub slot: usize,
    pub child: Child,
    pub started: Option<Instant>,
    pub created: Instant,
    pub retiring: bool,
}

pub struct Manager {
    pub pool: std::sync::Arc<Pool>,
    pub config: Config,
    pub owner: String,
    pub vms: BTreeMap<String, Vm>,
    // Hold the lock through cleanup, including remote runner deletion.
    _lock: File,
}

impl Drop for Manager {
    fn drop(&mut self) {
        self.pool.cancel(&self.owner);
        for vm in self.vms.values_mut() {
            let _ = vm.child.start_kill();
        }
        // flock is tied to the open file description. Another thread may have
        // forked a helper that briefly holds a copy until exec closes CLOEXEC
        // descriptors. Explicit unlock avoids a spurious lock after restart.
        let _ = FileExt::unlock(&self._lock);
    }
}

pub fn private_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}

fn private_dir(path: &Path) -> Result<()> {
    fs::DirBuilder::new().mode(0o700).create(path)?;
    Ok(())
}

fn owned_name(name: &str) -> bool {
    name.strip_prefix("avm-")
        .is_some_and(|s| Uuid::parse_str(s).is_ok_and(|id| id.to_string() == s))
}

impl Manager {
    pub fn new(config: Config) -> Result<Self> {
        let pool = Pool::new(config.vm.taps.len());
        Self::with_pool(config, pool)
    }

    pub fn with_pool(config: Config, pool: std::sync::Arc<Pool>) -> Result<Self> {
        if !config.state_dir.exists() {
            private_dir(&config.state_dir)?;
        }
        let meta = fs::symlink_metadata(&config.state_dir)?;
        ensure!(
            meta.is_dir() && !meta.file_type().is_symlink(),
            "state directory must not be a symlink"
        );
        ensure!(
            meta.permissions().mode() & 0o077 == 0,
            "state directory must have mode 0700"
        );
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .open(config.state_dir.join("lock"))?;
        lock.try_lock_exclusive()
            .context("another scaler owns the state directory")?;
        let identity_path = config.state_dir.join("identity.json");
        let identity: Identity = if identity_path.exists() {
            serde_json::from_slice(&fs::read(&identity_path)?)?
        } else {
            let identity = Identity {
                controller: Uuid::new_v4(),
                github_url: config.github_url.clone(),
                scale_set: config.scale_set.clone(),
                repository_id: config.repository_id,
                installation_id: config.installation_id,
            };
            private_write(&identity_path, &serde_json::to_vec(&identity)?)?;
            File::open(&config.state_dir)?.sync_all()?;
            identity
        };
        ensure!((identity.installation_id == 0 || identity.installation_id == config.installation_id)
            && identity.repository_id == config.repository_id
            && (identity.repository_id.is_some() || identity.github_url == config.github_url)
            && identity.scale_set == config.scale_set,
            "state belongs to another GitHub scope or scale set; drain it using its original configuration");
        let runs = config.state_dir.join("runs");
        if !runs.exists() {
            private_dir(&runs)?;
        }
        ensure!(
            fs::symlink_metadata(&runs)?.is_dir(),
            "runs must be a real directory"
        );
        Ok(Self {
            pool,
            owner: format!("actions-vm-{}", identity.controller),
            config,
            vms: BTreeMap::new(),
            _lock: lock,
        })
    }

    pub fn dir(&self, name: &str) -> Result<PathBuf> {
        ensure!(owned_name(name), "invalid local runner identity");
        Ok(self.config.state_dir.join("runs").join(name))
    }

    pub fn pending_names(&self) -> Result<Vec<String>> {
        let mut names = Vec::new();
        for entry in fs::read_dir(self.config.state_dir.join("runs"))? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            ensure!(
                owned_name(&name) && entry.file_type()?.is_dir(),
                "unexpected entry in owned runs directory"
            );
            if !self.vms.contains_key(&name) {
                names.push(name);
            }
        }
        Ok(names)
    }

    pub async fn recover(&self, api: &mut Api) -> Result<()> {
        for name in self.pending_names()? {
            // Includes an ambiguous JIT response: intent is durable before the HTTP POST.
            api.remove_runner(&name).await?;
            self.remove_files(&name)?;
            eprintln!("recovered runner {name}");
        }
        Ok(())
    }

    fn remove_files(&self, name: &str) -> Result<()> {
        let dir = self.dir(name)?;
        if dir.exists() {
            ensure!(
                fs::symlink_metadata(&dir)?.is_dir(),
                "refusing non-directory runner state"
            );
            fs::remove_dir_all(&dir)?;
            File::open(dir.parent().unwrap())?.sync_all()?;
        }
        Ok(())
    }

    pub fn count(&self) -> usize {
        self.vms.len()
    }

    pub fn mark_started(&mut self, name: &str) {
        if let Some(vm) = self.vms.get_mut(name) {
            // Duplicate delivery must not extend the execution deadline.
            vm.started.get_or_insert_with(Instant::now);
        }
    }

    pub fn mark_completed(&mut self, name: &str) {
        if let Some(vm) = self.vms.get_mut(name) {
            vm.retiring = true;
        }
    }

    pub async fn reap(&mut self, api: &mut Api) -> Result<()> {
        let mut retired = Vec::new();
        for (name, vm) in &mut self.vms {
            if vm.child.try_wait()?.is_some() {
                vm.retiring = true;
            }
            let timed_out = match vm.started {
                Some(at) => at.elapsed() >= Duration::from_secs(self.config.job_timeout_secs),
                None => {
                    vm.created.elapsed() >= Duration::from_secs(self.config.startup_timeout_secs)
                }
            };
            if timed_out && !vm.retiring {
                eprintln!(
                    "runner {name} exceeded its {} deadline",
                    if vm.started.is_some() {
                        "job"
                    } else {
                        "startup/idle"
                    }
                );
                vm.retiring = true;
            }
            if vm.retiring {
                // Keep the slot reserved until the child has actually stopped.
                vm.child.kill().await.context("stopping QEMU")?;
                retired.push(name.clone());
            }
        }
        for name in retired {
            // Retain VM entry/intent on API failure; retries are idempotent.
            api.remove_runner(&name).await?;
            self.remove_files(&name)?;
            self.vms.remove(&name);
            eprintln!("removed runner {name}");
        }
        self.recover(api).await
    }

    pub async fn spawn(&mut self, api: &mut Api) -> Result<bool> {
        let Some(lease) = self.pool.reserve(&self.owner) else {
            return Ok(false);
        };
        let slot = lease.slot;
        let id = Uuid::new_v4();
        let name = format!("avm-{id}");
        let dir = self.dir(&name)?;
        private_dir(&dir)?;
        File::open(dir.parent().unwrap())?.sync_all()?;
        // This directory is the durable registration intent. Cleanup can find the
        // registration by name even if JIT generation or process creation fails.
        let jit = api.jit(&name).await?;
        let seed_dir = dir.join("seed");
        private_dir(&seed_dir)?;
        private_write(&seed_dir.join("jitconfig"), jit.encoded.as_bytes())?;
        private_write(&seed_dir.join("runner-name"), name.as_bytes())?;
        let disk = dir.join("disk.qcow2");
        run(Command::new(&self.config.vm.qemu_img)
            .args(["create", "-f", "qcow2", "-F", "qcow2", "-b"])
            .arg(&self.config.vm.base_disk)
            .arg(&disk))
        .await
        .context("creating disposable disk")?;
        // IDE hard disks require a writable block node. Keep the shared boot
        // image immutable by giving OpenCore its own disposable overlay too.
        run(Command::new(&self.config.vm.qemu_img)
            .args(["create", "-f", "qcow2", "-F", "qcow2", "-b"])
            .arg(&self.config.vm.opencore_disk)
            .arg(dir.join("opencore.qcow2")))
        .await
        .context("creating disposable OpenCore disk")?;
        fs::copy(&self.config.vm.firmware_vars, dir.join("nvram.fd"))?;
        fs::set_permissions(dir.join("nvram.fd"), fs::Permissions::from_mode(0o600))?;
        run(Command::new(&self.config.vm.xorriso)
            .args([
                "-as",
                "mkisofs",
                "-quiet",
                "-J",
                "-r",
                "-V",
                "RUNNER_SEED",
                "-o",
            ])
            .arg(dir.join("seed.iso"))
            .arg(&seed_dir))
        .await
        .context("creating bootstrap ISO")?;
        fs::remove_dir_all(seed_dir)?;
        let log = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(dir.join("qemu.log"))?;
        let mut command = Command::new(&self.config.vm.qemu);
        command
            .args(qemu_args(&self.config, &dir, &name, slot, id))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::from(log));
        prepare_child(&mut command);
        let child = command.spawn().context("starting QEMU")?;
        self.vms.insert(
            name.clone(),
            Vm {
                _lease: lease,
                slot,
                child,
                started: None,
                created: Instant::now(),
                retiring: false,
            },
        );
        eprintln!("started runner {name} in slot {slot}");
        Ok(true)
    }

    /// Release local resources while retaining empty registration-intent directories.
    /// This also works after access revocation, when GitHub cleanup is impossible.
    pub async fn discard_local(&mut self) -> Result<()> {
        self.stop_all().await;
        self.vms.clear();
        self.pool.cancel(&self.owner);
        for name in self.pending_names()? {
            for entry in fs::read_dir(self.dir(&name)?)? {
                let entry = entry?;
                if entry.file_type()?.is_dir() {
                    fs::remove_dir_all(entry.path())?;
                } else {
                    fs::remove_file(entry.path())?;
                }
            }
        }
        Ok(())
    }

    /// Recover lightweight per-repository managers by stable ID, never by a
    /// repository name used as a filesystem path.
    pub fn stored_config(base: &Config, directory: PathBuf, id: u64) -> Result<Config> {
        let identity: Identity =
            serde_json::from_slice(&fs::read(directory.join("identity.json"))?)?;
        ensure!(
            identity.repository_id == Some(id),
            "repository state ID mismatch"
        );
        let mut config = base.clone();
        config.github_url = identity.github_url;
        config.repository_id = Some(id);
        config.state_dir = directory;
        config.validate()?;
        Ok(config)
    }

    pub async fn stop_all(&mut self) {
        for vm in self.vms.values_mut() {
            vm.retiring = true;
            if let Err(error) = vm.child.kill().await {
                eprintln!("QEMU stop failed: {error}");
            }
        }
    }
}

/// Separate from spawning so tests can verify disk and network ownership without KVM.
pub fn qemu_args(config: &Config, dir: &Path, name: &str, slot: usize, id: Uuid) -> Vec<String> {
    let v = &config.vm;
    let mut args = vec![
        "-enable-kvm".into(),
        "-nodefaults".into(),
        "-no-user-config".into(),
        "-display".into(),
        "none".into(),
        "-monitor".into(),
        "none".into(),
        "-serial".into(),
        "none".into(),
        "-no-reboot".into(),
        "-name".into(),
        name.into(),
        "-uuid".into(),
        id.to_string(),
        "-m".into(),
        v.memory_mib.to_string(),
        "-smp".into(),
        v.cpus.to_string(),
        "-sandbox".into(),
        "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny".into(),
    ];
    args.extend(v.hardware_args.clone());
    args.extend([
        "-drive".into(),
        format!(
            "if=pflash,format=raw,readonly=on,file={}",
            v.firmware_code.display()
        ),
        "-drive".into(),
        format!(
            "if=pflash,format=raw,file={}",
            dir.join("nvram.fd").display()
        ),
        "-device".into(),
        "ich9-ahci,id=sata".into(),
        "-drive".into(),
        format!(
            "id=opencore,if=none,format=qcow2,file={}",
            dir.join("opencore.qcow2").display()
        ),
        "-device".into(),
        "ide-hd,bus=sata.2,drive=opencore".into(),
        "-drive".into(),
        format!(
            "id=seed,if=none,format=raw,readonly=on,media=cdrom,file={}",
            dir.join("seed.iso").display()
        ),
        "-device".into(),
        "ide-cd,bus=sata.3,drive=seed".into(),
        "-drive".into(),
        format!(
            "id=os,if=none,format=qcow2,file={}",
            dir.join("disk.qcow2").display()
        ),
        "-device".into(),
        "ide-hd,bus=sata.4,drive=os".into(),
        "-device".into(),
        "VGA".into(),
        "-netdev".into(),
        format!(
            "tap,id=net0,ifname={},script=no,downscript=no",
            v.taps[slot]
        ),
        "-device".into(),
        format!("vmxnet3,netdev=net0,mac=52:54:00:78:00:{slot:02x}"),
    ]);
    args
}

fn prepare_child(command: &mut Command) {
    command.kill_on_drop(true);
    #[cfg(target_os = "linux")]
    {
        // No daemonized/orphan VMs, even if the controller is SIGKILLed.
        let parent = std::process::id() as libc::pid_t;
        unsafe {
            command.pre_exec(move || {
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                if libc::getppid() != parent {
                    return Err(std::io::Error::other(
                        "controller exited before child initialization",
                    ));
                }
                Ok(())
            });
        }
    }
}

async fn run(command: &mut Command) -> Result<()> {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    prepare_child(command);
    let status = tokio::time::timeout(Duration::from_secs(120), command.status())
        .await
        .context("VM preparation timed out")??;
    ensure!(status.success(), "VM preparation failed ({status})");
    Ok(())
}
