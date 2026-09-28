use crate::{
    api::{Api, Message, SessionLost},
    config::{Config, VmConfig},
    controller,
    vm::{qemu_args, Manager},
};
use serde_json::{json, Value};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    time::{Duration, Instant},
};
use tempfile::TempDir;
use wiremock::{
    matchers::{body_json, header, method, path, query_param},
    Mock, MockServer, Request, ResponseTemplate,
};

fn config(temp: &TempDir) -> Config {
    let root = temp.path();
    let c = Config {
        github_url: "https://github.com/example/repo".into(),
        discovery_interval_secs: 60,
        repository_id: None,
        scale_set: "macos-intel".into(),
        runner_group_id: 1,
        app_id: "123".into(),
        installation_id: 456,
        private_key_file: root.join("key.pem"),
        state_dir: root.join("state"),
        startup_timeout_secs: 900,
        job_timeout_secs: 3600,
        vm: VmConfig {
            qemu: root.join("qemu"),
            qemu_img: root.join("qemu-img"),
            xorriso: root.join("xorriso"),
            base_disk: root.join("base.qcow2"),
            opencore_disk: root.join("opencore.qcow2"),
            firmware_code: root.join("code.fd"),
            firmware_vars: root.join("vars.fd"),
            hardware_args: vec![
                "-machine".into(),
                "q35".into(),
                "-cpu".into(),
                "host".into(),
            ],
            taps: vec!["avm0".into(), "avm1".into()],
            memory_mib: 8192,
            cpus: 4,
        },
    };
    fs::write(
        &c.private_key_file,
        include_bytes!("../tests/fixtures/app-test-key.pem"),
    )
    .unwrap();
    for file in [
        &c.vm.base_disk,
        &c.vm.opencore_disk,
        &c.vm.firmware_code,
        &c.vm.firmware_vars,
    ] {
        fs::write(file, "golden").unwrap();
    }
    for (file, script) in [
        (&c.vm.qemu, "#!/bin/sh\nexec sleep 300\n"),
        (
            &c.vm.qemu_img,
            "#!/bin/sh\nfor last; do :; done\n: > \"$last\"\n",
        ),
        (
            &c.vm.xorriso,
            "#!/bin/sh\nwhile [ \"$1\" != -o ]; do shift; done\n: > \"$2\"\n",
        ),
    ] {
        fs::write(file, script).unwrap();
        fs::set_permissions(file, fs::Permissions::from_mode(0o755)).unwrap();
    }
    c
}

#[test]
fn omitted_github_url_enables_installation_discovery() {
    let temp = TempDir::new().unwrap();
    let mut value = serde_json::to_value(config(&temp)).unwrap();
    value.as_object_mut().unwrap().remove("github_url");
    let config: Config = serde_json::from_value(value).unwrap();
    config.validate().unwrap();
    assert!(config.github_url.is_empty());
}

#[test]
fn host_pool_enforces_fifo_and_releases_cancelled_waiters() {
    let pool = crate::pool::Pool::new(2);
    let a = pool.reserve("a").unwrap();
    let b = pool.reserve("b").unwrap();
    assert_ne!(a.slot, b.slot);
    assert!(pool.reserve("c").is_none());
    assert!(pool.reserve("d").is_none());
    drop(a);
    assert!(pool.reserve("b").is_none()); // Cannot jump ahead of C and D.
    let c = pool.reserve("c").unwrap();
    drop(b);
    pool.cancel("d");
    let b = pool.reserve("b").unwrap();
    assert_ne!(c.slot, b.slot);
}

#[tokio::test]
async fn installation_discovery_paginates_and_rejects_partial_scans() {
    let temp = TempDir::new().unwrap();
    let server = MockServer::start().await;
    let api = Api::fixture(config(&temp), &server.uri(), false);
    Mock::given(method("POST"))
        .and(path("/app/installations/456/access_tokens"))
        .respond_with(
            ResponseTemplate::new(201).set_body_json(json!({"token":"installation-secret"})),
        )
        .mount(&server)
        .await;
    let first: Vec<_> = (1..=100).map(|id| json!({"id":id, "full_name":format!("owner/repo{id}"), "archived":false, "disabled":false})).collect();
    Mock::given(method("GET"))
        .and(path("/installation/repositories"))
        .and(query_param("per_page", "100"))
        .and(query_param("page", "1"))
        .and(header("Authorization", "Bearer installation-secret"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"repositories":first})))
        .mount(&server)
        .await;
    let second = Mock::given(method("GET"))
        .and(path("/installation/repositories"))
        .and(query_param("page", "2"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({"repositories":[{"id":101,"full_name":"owner/last"}]})),
        )
        .mount_as_scoped(&server)
        .await;
    let repositories = api.repositories().await.unwrap();
    assert_eq!(repositories.len(), 101);
    assert_eq!(repositories.last().unwrap().full_name, "owner/last");
    drop(second);
    Mock::given(method("GET"))
        .and(path("/installation/repositories"))
        .and(query_param("page", "2"))
        .respond_with(ResponseTemplate::new(403))
        .mount(&server)
        .await;
    assert!(api.repositories().await.is_err());
}

#[tokio::test]
async fn multiple_repositories_share_capacity_and_revocation_releases_local_disks() {
    let temp = TempDir::new().unwrap();
    let mut a = config(&temp);
    a.repository_id = Some(101);
    a.state_dir = temp.path().join("a");
    let mut b = a.clone();
    b.repository_id = Some(102);
    b.github_url = "https://github.com/example/second".into();
    b.state_dir = temp.path().join("b");
    let pool = crate::pool::Pool::new(1);
    let server = MockServer::start().await;
    jit(&server).await;
    let mut api = Api::fixture(a.clone(), &server.uri(), true);
    let mut first = Manager::with_pool(a.clone(), pool.clone()).unwrap();
    let mut second = Manager::with_pool(b, pool).unwrap();
    assert!(first.spawn(&mut api).await.unwrap());
    assert!(!second.spawn(&mut api).await.unwrap());
    assert_eq!(first.count() + second.count(), 1);
    assert!(second.pending_names().unwrap().is_empty());
    // No API permission is needed to stop guests and remove their disks.
    first.discard_local().await.unwrap();
    let tombstone = first.pending_names().unwrap().pop().unwrap();
    assert_eq!(
        fs::read_dir(first.dir(&tombstone).unwrap())
            .unwrap()
            .count(),
        0
    );
    assert!(second.spawn(&mut api).await.unwrap());
    second.discard_local().await.unwrap();
    let owner = first.owner.clone();
    drop(first);
    a.github_url = "https://github.com/example/renamed".into();
    let first = Manager::new(a).unwrap();
    assert_eq!(owner, first.owner); // Numeric repository ID survives renames.
    empty_runners(&server).await;
    first.recover(&mut api).await.unwrap();
    assert!(first.pending_names().unwrap().is_empty());
}

#[tokio::test]
async fn fleet_restart_removes_stale_disks_without_repository_access() {
    let temp = TempDir::new().unwrap();
    let mut c = config(&temp);
    c.github_url.clear();
    let fleet = crate::fleet::Fleet::new(c.clone()).await.unwrap();
    let mut scoped = c.clone();
    scoped.github_url = "https://github.com/example/repo".into();
    scoped.repository_id = Some(101);
    scoped.state_dir = c.state_dir.join("repositories/101");
    let server = MockServer::start().await;
    jit(&server).await;
    let mut api = Api::fixture(scoped.clone(), &server.uri(), true);
    let mut manager = Manager::new(scoped.clone()).unwrap();
    manager.spawn(&mut api).await.unwrap();
    let name = manager.vms.keys().next().unwrap().clone();
    manager.stop_all().await;
    drop(manager);
    drop(fleet);
    let _fleet = crate::fleet::Fleet::new(c).await.unwrap();
    let intent = scoped.state_dir.join("runs").join(name);
    assert!(intent.is_dir());
    assert_eq!(fs::read_dir(intent).unwrap().count(), 0);
    // Startup used only local state, with no new GitHub requests or grants.
    assert_eq!(server.received_requests().await.unwrap().len(), 1);
}

#[tokio::test]
async fn fleet_adds_removes_and_renames_repositories_without_multiplying_capacity() {
    use crate::{api::Repository, fleet::Fleet};
    use wiremock::matchers::path_regex;
    let temp = TempDir::new().unwrap();
    let mut c = config(&temp);
    c.github_url.clear();
    c.vm.taps.truncate(1);
    let root = c.state_dir.clone();
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/app/installations/456/access_tokens"))
        .respond_with(
            ResponseTemplate::new(201).set_body_json(json!({"token":"installation-secret"})),
        )
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path_regex(
            "^/repos/owner/[^/]+/actions/runners/registration-token$",
        ))
        .respond_with(
            ResponseTemplate::new(201).set_body_json(json!({"token":"registration-secret"})),
        )
        .mount(&server)
        .await;
    let base = server.uri();
    Mock::given(method("POST"))
        .and(path("/actions/runner-registration"))
        .respond_with(move |r: &Request| {
            let value: Value = serde_json::from_slice(&r.body).unwrap();
            let repo = value["url"].as_str().unwrap().rsplit('/').next().unwrap();
            ResponseTemplate::new(200).set_body_json(
                json!({"url":format!("{base}/tenant/{repo}"),"token":"admin-secret"}),
            )
        })
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path_regex("/runnerscalesets$"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"value":[{"id":42}]})))
        .mount(&server)
        .await;
    let base = server.uri();
    Mock::given(method("POST")).and(path_regex("/runnerscalesets/42/sessions$"))
        .respond_with(move |r: &Request| {
            let repo = r.url.path().split('/').nth(2).unwrap();
            ResponseTemplate::new(200).set_body_json(json!({"sessionId":"00000000-0000-4000-8000-000000000001", "messageQueueUrl":format!("{base}/queue/{repo}"),"messageQueueAccessToken":"queue-token", "statistics":{"totalAssignedJobs":1}}))
        }).mount(&server).await;
    Mock::given(method("POST")).and(path_regex("/generatejitconfig$"))
        .respond_with(|r: &Request| {
            let value: Value = serde_json::from_slice(&r.body).unwrap();
            ResponseTemplate::new(200).set_body_json(json!({"runner":{"id":11,"name":value["name"],"runnerScaleSetId":42},"encodedJITConfig":"jit-secret"}))
        }).mount(&server).await;
    Mock::given(method("GET"))
        .and(path_regex("/agents$"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"value":[]})))
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path_regex("/sessions/[^/]+$"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path_regex("^/queue/"))
        .respond_with(ResponseTemplate::new(202).set_delay(Duration::from_secs(30)))
        .mount(&server)
        .await;

    fn seeds(root: &std::path::Path) -> Vec<u64> {
        let mut ids = vec![];
        for repo in fs::read_dir(root.join("repositories")).unwrap() {
            let repo = repo.unwrap();
            let runs = repo.path().join("runs");
            if !runs.exists() {
                continue;
            }
            for run in fs::read_dir(runs).unwrap() {
                if run.unwrap().path().join("seed.iso").exists() {
                    ids.push(repo.file_name().to_str().unwrap().parse().unwrap());
                }
            }
        }
        ids
    }
    async fn wait_for(root: &std::path::Path, id: Option<u64>) -> u64 {
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let ids = seeds(root);
                assert!(ids.len() <= 1, "global capacity exceeded");
                if ids.len() == 1 && id.is_none_or(|id| id == ids[0]) {
                    return ids[0];
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .unwrap()
    }
    let mut fleet = Fleet::new(c.clone()).await.unwrap();
    fleet.set_test_api(Api::fixture(c, &server.uri(), false));
    let a = Repository {
        id: 101,
        full_name: "owner/a".into(),
        archived: false,
        disabled: false,
    };
    let b = Repository {
        id: 102,
        full_name: "owner/b".into(),
        archived: false,
        disabled: false,
    };
    fleet.reconcile(vec![a.clone(), b.clone()]).await.unwrap();
    assert_eq!(fleet.repository_ids(), vec![101, 102]);
    let active = wait_for(&root, None).await;
    let mut survivor = if active == 101 { b } else { a };
    fleet.reconcile(vec![survivor.clone()]).await.unwrap();
    wait_for(&root, Some(survivor.id)).await;
    survivor.full_name = "owner/renamed".into();
    fleet.reconcile(vec![survivor.clone()]).await.unwrap();
    wait_for(&root, Some(survivor.id)).await;
    survivor.archived = true;
    fleet.reconcile(vec![survivor]).await.unwrap();
    assert!(fleet.repository_ids().is_empty());
    assert!(seeds(&root).is_empty());
    fleet.shutdown().await;
}

fn session(server: &MockServer, token: &str) -> Value {
    json!({"sessionId": "00000000-0000-4000-8000-000000000001", "messageQueueUrl": format!("{}/queue?tokenScope=runner", server.uri()),
        "messageQueueAccessToken": token, "statistics": {"totalAssignedJobs": 0}})
}

async fn open(api: &mut Api, server: &MockServer) {
    Mock::given(method("POST"))
        .and(path("/tenant/_apis/runtime/runnerscalesets/42/sessions"))
        .and(header("Authorization", "Bearer admin-secret"))
        .respond_with(ResponseTemplate::new(200).set_body_json(session(server, "queue-old")))
        .mount(server)
        .await;
    api.open_session("test-owner").await.unwrap();
}

async fn jit(server: &MockServer) {
    Mock::given(method("POST")).and(path("/tenant/_apis/runtime/runnerscalesets/42/generatejitconfig"))
        .respond_with(|request: &Request| {
            let body: Value = serde_json::from_slice(&request.body).unwrap();
            ResponseTemplate::new(200).set_body_json(json!({"runner": {"id": 11, "name": body["name"], "runnerScaleSetId": 42}, "encodedJITConfig": "jit-secret"}))
        }).mount(server).await;
}

async fn empty_runners(server: &MockServer) {
    Mock::given(method("GET"))
        .and(path("/tenant/_apis/distributedtask/pools/0/agents"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"value": []})))
        .mount(server)
        .await;
}

fn message(id: u64, assigned: usize, jobs: Value) -> Message {
    serde_json::from_value(json!({"messageId": id, "messageType": "RunnerScaleSetJobMessages", "body": jobs.to_string(), "statistics": {"totalAssignedJobs": assigned}})).unwrap()
}

#[test]
fn config_rejects_ambiguous_scope_and_lifecycle_overrides() {
    let temp = TempDir::new().unwrap();
    let mut c = config(&temp);
    c.validate().unwrap();
    c.check_files().unwrap();
    assert_eq!(
        c.registration_path().unwrap(),
        "repos/example/repo/actions/runners/registration-token"
    );
    c.github_url = "https://github.com/example".into();
    assert_eq!(
        c.registration_path().unwrap(),
        "orgs/example/actions/runners/registration-token"
    );
    for url in [
        "https://github.com/example/repo/issues",
        "https://github.com.evil/example",
        "https://user@github.com/example",
        "http://github.com/example",
        "https://github.com/example?token=secret",
    ] {
        c.github_url = url.into();
        assert!(c.validate().is_err());
    }
    c = config(&temp);
    c.vm.hardware_args = vec!["-daemonize".into(), "yes".into()];
    assert!(c.validate().is_err());
    c.vm.hardware_args = vec!["-device".into(), "virtio-9p,fsdev=host".into()];
    assert!(c.validate().is_err());
    c.vm.hardware_args.clear();
    c.vm.taps = vec!["avm0".into(), "avm0".into()];
    assert!(c.validate().is_err());
}

#[test]
fn qemu_owns_writable_disks_and_has_no_host_shares_or_daemonization() {
    let temp = TempDir::new().unwrap();
    let c = config(&temp);
    let id = uuid::Uuid::new_v4();
    let args = qemu_args(&c, &temp.path().join("run"), "runner", 1, id);
    assert!(args.contains(&"-enable-kvm".into()));
    assert!(args.contains(&format!(
        "if=pflash,format=raw,readonly=on,file={}",
        c.vm.firmware_code.display()
    )));
    assert!(args
        .iter()
        .any(|s| s.contains("readonly=on") && s.contains("opencore.qcow2")));
    assert!(args
        .iter()
        .any(|s| s == "tap,id=net0,ifname=avm1,script=no,downscript=no"));
    assert!(args.iter().any(|s| s.ends_with("run/disk.qcow2")));
    assert!(!args
        .iter()
        .any(|s| s.contains("base.qcow2") || s == "-daemonize" || s == "-virtfs"));
}

#[test]
fn state_lock_scope_and_path_traversal() {
    let temp = TempDir::new().unwrap();
    let c = config(&temp);
    let manager = Manager::new(c.clone()).unwrap();
    assert!(Manager::new(c.clone()).is_err());
    assert!(manager.dir("../../base.qcow2").is_err());
    let owner = manager.owner.clone();
    drop(manager);
    let manager = Manager::new(c.clone()).unwrap();
    assert_eq!(manager.owner, owner);
    drop(manager);
    let mut changed = c;
    changed.scale_set = "other".into();
    assert!(Manager::new(changed).is_err());
}

#[test]
fn rejects_unowned_state_and_world_readable_directory() {
    let temp = TempDir::new().unwrap();
    let c = config(&temp);
    let manager = Manager::new(c.clone()).unwrap();
    std::os::unix::fs::symlink(
        temp.path(),
        c.state_dir
            .join("runs")
            .join(format!("avm-{}", uuid::Uuid::new_v4())),
    )
    .unwrap();
    assert!(manager.pending_names().is_err());
    drop(manager);
    fs::set_permissions(&c.state_dir, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(Manager::new(c).is_err());
}

#[tokio::test]
async fn app_authentication_registration_and_scale_set_creation() {
    let temp = TempDir::new().unwrap();
    let c = config(&temp);
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/app/installations/456/access_tokens"))
        .respond_with(
            ResponseTemplate::new(201).set_body_json(json!({"token": "installation-secret"})),
        )
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path(
            "/repos/example/repo/actions/runners/registration-token",
        ))
        .and(header("Authorization", "Bearer installation-secret"))
        .respond_with(
            ResponseTemplate::new(201).set_body_json(json!({"token": "registration-secret"})),
        )
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/actions/runner-registration"))
        .and(header("Authorization", "RemoteAuth registration-secret"))
        .and(body_json(
            json!({"url": c.github_url, "runner_event": "register"}),
        ))
        .respond_with(ResponseTemplate::new(200).set_body_json(
            json!({"url": format!("{}/tenant/", server.uri()), "token": "admin-secret"}),
        ))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/tenant/_apis/runtime/runnerscalesets"))
        .and(query_param("api-version", "6.0-preview"))
        .and(query_param("name", "macos-intel"))
        .and(header("Authorization", "Bearer admin-secret"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"value": []})))
        .mount(&server)
        .await;
    Mock::given(method("POST")).and(path("/tenant/_apis/runtime/runnerscalesets"))
        .and(body_json(json!({"name": "macos-intel", "runnerGroupId": 1, "labels": [{"name": "macos-intel", "type": "System"}], "RunnerSetting": {"disableUpdate": false}})))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"id": 42}))).expect(1).mount(&server).await;
    let mut api = Api::fixture(c, &server.uri(), false);
    api.ensure_scale_set().await.unwrap();
    assert_eq!(api.scale_set_id, 42);
}

#[tokio::test]
async fn queue_refresh_capacity_acquisition_and_acknowledgment() {
    let temp = TempDir::new().unwrap();
    let c = config(&temp);
    let server = MockServer::start().await;
    let mut api = Api::fixture(c, &server.uri(), true);
    open(&mut api, &server).await;
    Mock::given(method("GET"))
        .and(path("/queue"))
        .and(header("Authorization", "Bearer queue-old"))
        .respond_with(ResponseTemplate::new(401))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("PATCH")).and(path("/tenant/_apis/runtime/runnerscalesets/42/sessions/00000000-0000-4000-8000-000000000001"))
        .respond_with(ResponseTemplate::new(200).set_body_json(session(&server, "queue-new"))).expect(1).mount(&server).await;
    Mock::given(method("GET")).and(path("/queue")).and(header("Authorization", "Bearer queue-new"))
        .and(header("X-ScaleSetMaxCapacity", "2")).and(query_param("lastMessageId", "7")).and(query_param("tokenScope", "runner"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"messageId": 8, "messageType": "RunnerScaleSetJobMessages", "body": "[]", "statistics": {"totalAssignedJobs": 0}}))).expect(1).mount(&server).await;
    Mock::given(method("POST"))
        .and(path("/tenant/_apis/runtime/runnerscalesets/42/acquirejobs"))
        .and(header("Authorization", "Bearer queue-new"))
        .and(body_json(json!([101, 102])))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"value": [101,102]})))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path("/queue/8"))
        .and(query_param("tokenScope", "runner"))
        .and(header("Authorization", "Bearer queue-new"))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    assert_eq!(api.poll(7, 2).await.unwrap().unwrap().message_id, 8);
    api.acquire(vec![101, 102]).await.unwrap();
    api.acknowledge(8).await.unwrap();
}

#[tokio::test]
async fn expired_session_requires_restart_and_errors_do_not_include_secrets() {
    let temp = TempDir::new().unwrap();
    let server = MockServer::start().await;
    let mut api = Api::fixture(config(&temp), &server.uri(), true);
    open(&mut api, &server).await;
    Mock::given(method("GET"))
        .and(path("/queue"))
        .respond_with(ResponseTemplate::new(404).set_body_string("super-secret-error-body"))
        .mount(&server)
        .await;
    let err = api.poll(0, 2).await.err().unwrap();
    assert!(err.is::<SessionLost>());
    assert!(!format!("{err:#}").contains("super-secret"));
}

#[tokio::test]
async fn refuses_cross_scale_set_runner_removal() {
    let temp = TempDir::new().unwrap();
    let server = MockServer::start().await;
    let mut api = Api::fixture(config(&temp), &server.uri(), true);
    Mock::given(method("GET"))
        .and(path("/tenant/_apis/distributedtask/pools/0/agents"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(
                json!({"value": [{"id": 9, "name": "runner", "runnerScaleSetId": 99}]}),
            ),
        )
        .mount(&server)
        .await;
    assert!(api.remove_runner("runner").await.is_err());
    assert!(!server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .any(|r| r.method == "DELETE"));
}

#[tokio::test]
async fn disposable_vms_are_bounded_redelivery_safe_and_cleaned_on_completion() {
    let temp = TempDir::new().unwrap();
    let c = config(&temp);
    let server = MockServer::start().await;
    jit(&server).await;
    empty_runners(&server).await;
    let mut api = Api::fixture(c.clone(), &server.uri(), true);
    let mut manager = Manager::new(c.clone()).unwrap();
    let mut assigned = 0;
    let msg = message(1, 10, json!([]));
    controller::apply(&mut api, &mut manager, &msg, &mut assigned)
        .await
        .unwrap();
    assert_eq!(manager.count(), 2);
    controller::apply(&mut api, &mut manager, &msg, &mut assigned)
        .await
        .unwrap();
    assert_eq!(manager.count(), 2);
    let names: Vec<_> = manager.vms.keys().cloned().collect();
    for name in &names {
        let dir = manager.dir(name).unwrap();
        assert!(dir.join("disk.qcow2").exists());
        assert!(dir.join("seed.iso").exists());
        assert!(!dir.join("seed").exists());
        assert_eq!(fs::read_to_string(dir.join("nvram.fd")).unwrap(), "golden");
    }
    manager.mark_started(&names[0]);
    let at = manager.vms[&names[0]].started;
    manager.mark_started(&names[0]);
    assert_eq!(manager.vms[&names[0]].started, at);
    let complete = message(
        2,
        0,
        json!([
            {"messageType": "JobCompleted", "runnerName": names[0]},
            {"messageType": "JobCompleted", "runnerName": names[1]},
            {"messageType": "JobCompleted", "runnerName": "../../unrelated"}
        ]),
    );
    controller::apply(&mut api, &mut manager, &complete, &mut assigned)
        .await
        .unwrap();
    controller::apply(&mut api, &mut manager, &complete, &mut assigned)
        .await
        .unwrap();
    assert_eq!(manager.count(), 0);
    assert!(manager.pending_names().unwrap().is_empty());
    assert_eq!(fs::read_to_string(&c.vm.base_disk).unwrap(), "golden");
    assert_eq!(fs::read_to_string(&c.vm.firmware_vars).unwrap(), "golden");
}

#[tokio::test]
async fn failed_startup_retains_intent_and_restart_recovers_it() {
    let temp = TempDir::new().unwrap();
    let c = config(&temp);
    let server = MockServer::start().await;
    jit(&server).await;
    empty_runners(&server).await;
    fs::write(&c.vm.qemu_img, "#!/bin/sh\nexit 1\n").unwrap();
    let mut api = Api::fixture(c.clone(), &server.uri(), true);
    let mut manager = Manager::new(c.clone()).unwrap();
    assert!(manager.spawn(&mut api).await.is_err());
    assert_eq!(manager.pending_names().unwrap().len(), 1);
    drop(manager);
    let manager = Manager::new(c).unwrap();
    manager.recover(&mut api).await.unwrap();
    assert!(manager.pending_names().unwrap().is_empty());
}

#[tokio::test]
async fn lost_jit_response_leaves_a_recoverable_registration_intent() {
    let temp = TempDir::new().unwrap();
    let c = config(&temp);
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path(
            "/tenant/_apis/runtime/runnerscalesets/42/generatejitconfig",
        ))
        .respond_with(ResponseTemplate::new(502))
        .mount(&server)
        .await;
    empty_runners(&server).await;
    let mut api = Api::fixture(c.clone(), &server.uri(), true);
    let mut manager = Manager::new(c).unwrap();
    assert!(manager.spawn(&mut api).await.is_err());
    assert_eq!(manager.pending_names().unwrap().len(), 1);
    manager.recover(&mut api).await.unwrap();
    assert!(manager.pending_names().unwrap().is_empty());
}

#[tokio::test]
async fn deadlines_and_exited_qemu_are_reaped_even_when_github_is_down() {
    let temp = TempDir::new().unwrap();
    let c = config(&temp);
    let server = MockServer::start().await;
    jit(&server).await;
    let mut api = Api::fixture(c.clone(), &server.uri(), true);
    let mut manager = Manager::new(c).unwrap();
    manager.spawn(&mut api).await.unwrap();
    manager.spawn(&mut api).await.unwrap();
    for vm in manager.vms.values_mut() {
        vm.created = Instant::now() - Duration::from_secs(1000);
    }
    assert!(manager.reap(&mut api).await.is_err());
    assert_eq!(manager.count(), 2); // Slots stay reserved while cleanup is pending.
    for vm in manager.vms.values_mut() {
        assert!(vm.child.try_wait().unwrap().is_some());
    }
    empty_runners(&server).await;
    manager.reap(&mut api).await.unwrap();
    assert_eq!(manager.count(), 0);
    manager.spawn(&mut api).await.unwrap();
    manager
        .vms
        .values_mut()
        .next()
        .unwrap()
        .child
        .kill()
        .await
        .unwrap();
    manager.reap(&mut api).await.unwrap();
    assert_eq!(manager.count(), 0);
}

#[tokio::test]
async fn acquisition_failure_does_not_spawn_or_acknowledge() {
    let temp = TempDir::new().unwrap();
    let c = config(&temp);
    let server = MockServer::start().await;
    let mut api = Api::fixture(c.clone(), &server.uri(), true);
    open(&mut api, &server).await;
    let mut manager = Manager::new(c).unwrap();
    let mut assigned = 0;
    let msg = message(
        1,
        1,
        json!([{"messageType":"JobAvailable", "runnerRequestId": 123}]),
    );
    assert!(
        controller::apply(&mut api, &mut manager, &msg, &mut assigned)
            .await
            .is_err()
    );
    assert_eq!(manager.count(), 0);
    assert!(!server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .any(|r| r.method == "DELETE"));
}

#[test]
fn capacity_and_unknown_message_validation() {
    assert_eq!(controller::target(usize::MAX, 2), 2);
    assert_eq!(controller::target(0, 2), 0);
    let mut msg = message(0, 0, json!([]));
    msg.message_type = "Unknown".into();
    assert!(msg.jobs().is_err());
}

#[tokio::test]
async fn listener_only_acknowledges_after_failed_provisioning_has_recovered() {
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };
    let temp = TempDir::new().unwrap();
    let c = config(&temp);
    let server = MockServer::start().await;
    let mut api = Api::fixture(c.clone(), &server.uri(), true);
    open(&mut api, &server).await;
    empty_runners(&server).await;
    let attempts = Arc::new(AtomicUsize::new(0));
    let acknowledgments = Arc::new(AtomicUsize::new(0));
    let attempts_for_jit = attempts.clone();
    Mock::given(method("POST")).and(path("/tenant/_apis/runtime/runnerscalesets/42/generatejitconfig"))
        .respond_with(move |request: &Request| {
            if attempts_for_jit.fetch_add(1, Ordering::SeqCst) == 0 { return ResponseTemplate::new(502); }
            let body: Value = serde_json::from_slice(&request.body).unwrap();
            ResponseTemplate::new(200).set_body_json(json!({"runner": {"id": 11, "name": body["name"], "runnerScaleSetId": 42}, "encodedJITConfig": "jit-secret"}))
        }).mount(&server).await;
    Mock::given(method("POST"))
        .and(path("/tenant/_apis/runtime/runnerscalesets/42/acquirejobs"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"value": [123]})))
        .mount(&server)
        .await;
    let ack_for_poll = acknowledgments.clone();
    Mock::given(method("GET")).and(path("/queue"))
        .respond_with(move |_: &Request| {
            if ack_for_poll.load(Ordering::SeqCst) > 0 { return ResponseTemplate::new(404); }
            ResponseTemplate::new(200).set_body_json(json!({"messageId": 1, "messageType": "RunnerScaleSetJobMessages", "body": "[{\"messageType\":\"JobAvailable\",\"runnerRequestId\":123}]", "statistics": {"totalAssignedJobs": 1}}))
        }).mount(&server).await;
    let ack_for_delete = acknowledgments.clone();
    let runs = c.state_dir.join("runs");
    Mock::given(method("DELETE"))
        .and(path("/queue/1"))
        .respond_with(move |_: &Request| {
            let entries: Vec<_> = fs::read_dir(&runs).unwrap().collect();
            assert_eq!(entries.len(), 1);
            assert!(entries[0]
                .as_ref()
                .unwrap()
                .path()
                .join("seed.iso")
                .exists());
            ack_for_delete.fetch_add(1, Ordering::SeqCst);
            ResponseTemplate::new(204)
        })
        .mount(&server)
        .await;
    let mut manager = Manager::new(c).unwrap();
    let error = tokio::time::timeout(
        Duration::from_secs(10),
        controller::listen(&mut api, &mut manager),
    )
    .await
    .unwrap()
    .unwrap_err();
    assert!(error.is::<SessionLost>());
    assert_eq!(attempts.load(Ordering::SeqCst), 2);
    assert_eq!(acknowledgments.load(Ordering::SeqCst), 1);
    assert_eq!(manager.count(), 1);
    assert!(manager
        .vms
        .values_mut()
        .next()
        .unwrap()
        .child
        .try_wait()
        .unwrap()
        .is_none());
    manager.stop_all().await;
    manager.reap(&mut api).await.unwrap();
}
