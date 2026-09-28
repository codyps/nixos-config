use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::{Path, PathBuf},
};

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    /// Empty (default): discover every repository granted to this installation.
    /// A nonempty URL retains explicit single-repository/organization mode.
    #[serde(default)]
    pub github_url: String,
    #[serde(default = "default_discovery_interval")]
    pub discovery_interval_secs: u64,
    /// Set internally for discovered repositories; stable across renames.
    #[serde(skip)]
    pub repository_id: Option<u64>,
    pub scale_set: String,
    #[serde(default = "default_group")]
    pub runner_group_id: u64,
    pub app_id: String,
    pub installation_id: u64,
    pub private_key_file: PathBuf,
    pub state_dir: PathBuf,
    pub vm: VmConfig,
    #[serde(default = "default_startup")]
    pub startup_timeout_secs: u64,
    #[serde(default = "default_runtime")]
    pub job_timeout_secs: u64,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct VmConfig {
    pub qemu: PathBuf,
    pub qemu_img: PathBuf,
    pub xorriso: PathBuf,
    pub base_disk: PathBuf,
    pub opencore_disk: PathBuf,
    pub firmware_code: PathBuf,
    pub firmware_vars: PathBuf,
    /// Root-managed QEMU device options, one argument per entry. Never a shell command.
    /// Must supply machine, CPU and SMC settings appropriate for the golden image.
    pub hardware_args: Vec<String>,
    /// One pre-created, isolated TAP interface per slot. This is the capacity limit.
    pub taps: Vec<String>,
    #[serde(default = "default_memory")]
    pub memory_mib: u32,
    #[serde(default = "default_cpus")]
    pub cpus: u32,
}
fn default_group() -> u64 {
    1
}
fn default_discovery_interval() -> u64 {
    60
}
fn default_startup() -> u64 {
    900
}
fn default_runtime() -> u64 {
    21600
}
fn default_memory() -> u32 {
    8192
}
fn default_cpus() -> u32 {
    4
}

impl Config {
    pub fn read(path: &Path) -> Result<Self> {
        let config: Self = serde_json::from_slice(&fs::read(path)?)?;
        config.validate()?;
        Ok(config)
    }

    pub fn registration_path(&self) -> Result<String> {
        let url = reqwest::Url::parse(&self.github_url)?;
        ensure!(
            url.scheme() == "https"
                && url.host_str() == Some("github.com")
                && url.port().is_none()
                && url.username().is_empty()
                && url.password().is_none()
                && url.query().is_none()
                && url.fragment().is_none(),
            "github_url must be a github.com HTTPS repository or organization URL"
        );
        let parts: Vec<_> = url.path().trim_matches('/').split('/').collect();
        ensure!(
            parts.iter().all(|s| !s.is_empty()
                && s.bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
                && *s != "."
                && *s != ".."),
            "invalid GitHub scope"
        );
        match parts.as_slice() {
            [owner] => Ok(format!("orgs/{owner}/actions/runners/registration-token")),
            [owner, repo] => Ok(format!(
                "repos/{owner}/{repo}/actions/runners/registration-token"
            )),
            _ => anyhow::bail!("github_url must select one repository or organization"),
        }
    }

    pub fn validate(&self) -> Result<()> {
        if !self.github_url.is_empty() {
            self.registration_path()?;
        }
        ensure!(
            self.discovery_interval_secs >= 10,
            "discovery interval must be at least 10 seconds"
        );
        ensure!(
            !self.app_id.is_empty() && self.installation_id > 0,
            "GitHub App identity is required"
        );
        ensure!(
            !self.scale_set.is_empty()
                && self.scale_set.len() <= 64
                && self
                    .scale_set
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"-_".contains(&c)),
            "invalid scale_set name"
        );
        ensure!(
            self.startup_timeout_secs >= 30 && self.job_timeout_secs >= 60,
            "timeouts too short"
        );
        ensure!(
            (1..=32).contains(&self.vm.taps.len()),
            "provide 1 to 32 TAP slots"
        );
        let mut unique = std::collections::HashSet::new();
        for tap in &self.vm.taps {
            ensure!(
                !tap.is_empty()
                    && tap.len() <= 15
                    && tap
                        .bytes()
                        .all(|c| c.is_ascii_alphanumeric() || b"-_".contains(&c))
                    && unique.insert(tap),
                "invalid or duplicate TAP name"
            );
        }
        ensure!(
            self.vm.memory_mib >= 1024 && self.vm.cpus > 0,
            "invalid VM resources"
        );
        for path in [
            &self.private_key_file,
            &self.state_dir,
            &self.vm.qemu,
            &self.vm.qemu_img,
            &self.vm.xorriso,
            &self.vm.base_disk,
            &self.vm.opencore_disk,
            &self.vm.firmware_code,
            &self.vm.firmware_vars,
        ] {
            ensure!(
                path.is_absolute(),
                "paths must be absolute: {}",
                path.display()
            );
            ensure!(
                !path.as_os_str().as_encoded_bytes().contains(&b','),
                "QEMU paths cannot contain commas"
            );
        }
        // The manager owns process lifetime, disks, networking and control sockets.
        // Only hardware tuning belongs here. No daemonization or guest host mounts.
        ensure!(
            self.vm.hardware_args.len().is_multiple_of(2),
            "hardware_args must be option/value pairs"
        );
        for pair in self.vm.hardware_args.chunks(2) {
            ensure!(
                ["-machine", "-cpu", "-device", "-smbios", "-global"].contains(&pair[0].as_str()),
                "unsupported hardware option {}",
                pair[0]
            );
            if pair[0] == "-device" {
                ensure!(
                    pair[1].starts_with("isa-applesmc,"),
                    "only the Apple SMC device may be added through hardware_args"
                );
            }
        }
        Ok(())
    }

    pub fn check_files(&self) -> Result<()> {
        for path in [
            &self.private_key_file,
            &self.vm.qemu,
            &self.vm.qemu_img,
            &self.vm.xorriso,
            &self.vm.base_disk,
            &self.vm.opencore_disk,
            &self.vm.firmware_code,
            &self.vm.firmware_vars,
        ] {
            ensure!(
                fs::metadata(path)
                    .with_context(|| format!("reading {}", path.display()))?
                    .is_file(),
                "not a file: {}",
                path.display()
            );
        }
        Ok(())
    }
}
