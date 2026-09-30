//! Minimal wire implementation of github.com/actions/scaleset.
//! Protocol reference: e6daac702355cdb5b880b4fbdcf6d85dcd9e48e5 (MIT).
use crate::config::Config;
use anyhow::{bail, ensure, Context, Result};
use reqwest::{Client, Method, StatusCode, Url};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const SETS: &str = "_apis/runtime/runnerscalesets";
const RUNNERS: &str = "_apis/distributedtask/pools/0/agents";

fn decode<T: serde::de::DeserializeOwned>(value: Value) -> Result<T> {
    // serde's Value deserializer can include the offending string in its error.
    // Responses contain credentials, so discard those details before logging.
    serde_json::from_value(value).map_err(|_| anyhow::anyhow!("invalid service response schema"))
}

#[derive(Debug)]
pub struct SessionLost;
impl std::fmt::Display for SessionLost {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("scale-set session lost; restart required")
    }
}
impl std::error::Error for SessionLost {}

#[derive(Clone, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Statistics {
    pub total_assigned_jobs: usize,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub session_id: String,
    pub message_queue_url: String,
    pub message_queue_access_token: String,
    // Session refresh returns null statistics; the upstream wire type is optional.
    // https://github.com/actions/scaleset/blob/e6daac702355cdb5b880b4fbdcf6d85dcd9e48e5/types.go#L116-L123
    pub statistics: Option<Statistics>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    pub message_id: u64,
    pub message_type: String,
    #[serde(default)]
    pub body: String,
    pub statistics: Option<Statistics>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JobMessage {
    pub message_type: String,
    #[serde(default)]
    pub runner_request_id: u64,
    #[serde(default)]
    pub runner_name: String,
}

impl Message {
    pub fn jobs(&self) -> Result<Vec<JobMessage>> {
        ensure!(
            self.message_type == "RunnerScaleSetJobMessages",
            "unknown scale-set message envelope"
        );
        if self.body.is_empty() {
            return Ok(vec![]);
        }
        serde_json::from_str(&self.body).context("invalid job message batch")
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Runner {
    pub id: u64,
    pub name: String,
    pub runner_scale_set_id: u64,
}

#[derive(Deserialize)]
pub struct Jit {
    pub runner: Runner,
    #[serde(rename = "encodedJITConfig")]
    pub encoded: String,
}

#[derive(Deserialize)]
struct Connection {
    url: String,
    token: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct Repository {
    pub id: u64,
    pub full_name: String,
    #[serde(default)]
    pub archived: bool,
    #[serde(default)]
    pub disabled: bool,
}

pub struct Api {
    http: Client,
    config: Config,
    github_api: String,
    connection: Option<(Connection, Instant)>,
    pub scale_set_id: u64,
    pub session: Option<Session>,
}

impl Api {
    pub(crate) fn scoped(&self, config: Config) -> Self {
        Self {
            http: self.http.clone(),
            config,
            github_api: self.github_api.clone(),
            connection: None,
            scale_set_id: 0,
            session: None,
        }
    }

    #[cfg(test)]
    pub(crate) fn fixture(config: Config, base: &str, authenticated: bool) -> Self {
        let mut api = Self::new(config).unwrap();
        api.github_api = base.into();
        if authenticated {
            api.connection = Some((
                Connection {
                    url: format!("{base}/tenant/"),
                    token: "admin-secret".into(),
                },
                Instant::now(),
            ));
        }
        api.scale_set_id = 42;
        api
    }

    pub fn new(config: Config) -> Result<Self> {
        Ok(Self {
            http: Client::builder()
                .timeout(Duration::from_secs(75))
                .connect_timeout(Duration::from_secs(15))
                .redirect(reqwest::redirect::Policy::none())
                .user_agent(concat!("actions-vm-scaler/", env!("CARGO_PKG_VERSION")))
                .build()?,
            config,
            github_api: "https://api.github.com".into(),
            connection: None,
            scale_set_id: 0,
            session: None,
        })
    }

    fn checked_url(&self, raw: &str) -> Result<Url> {
        let url = Url::parse(raw).context("invalid service URL")?;
        let secure = url.scheme() == "https";
        #[cfg(test)]
        let secure = secure || (url.scheme() == "http" && url.host_str() == Some("127.0.0.1"));
        ensure!(
            secure
                && url.username().is_empty()
                && url.password().is_none()
                && url.fragment().is_none(),
            "service requires an HTTPS URL without embedded credentials"
        );
        Ok(url)
    }

    async fn send(
        &self,
        method: Method,
        url: Url,
        auth: &str,
        body: Option<&Value>,
        capacity: Option<usize>,
    ) -> Result<(StatusCode, Value)> {
        let mut request = self
            .http
            .request(method, url)
            .header("Authorization", auth)
            .header("Accept", "application/json; api-version=6.0-preview");
        if let Some(body) = body {
            request = request.json(body);
        }
        if let Some(capacity) = capacity {
            request = request.header("X-ScaleSetMaxCapacity", capacity);
        }
        // Do not expose response bodies, request URLs or credentials in errors.
        let mut response = request
            .send()
            .await
            .map_err(|_| anyhow::anyhow!("HTTP transport failed"))?;
        let status = response.status();
        if status == StatusCode::TOO_MANY_REQUESTS || status == StatusCode::SERVICE_UNAVAILABLE {
            if let Some(seconds) = response
                .headers()
                .get("retry-after")
                .and_then(|s| s.to_str().ok())
                .and_then(|s| s.parse::<u64>().ok())
            {
                tokio::time::sleep(Duration::from_secs(seconds.min(300))).await;
            }
        }
        if !status.is_success() {
            return Ok((status, Value::Null));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| anyhow::anyhow!("reading HTTP response failed"))?
        {
            ensure!(
                bytes.len() + chunk.len() <= 8 * 1024 * 1024,
                "HTTP response exceeds size limit"
            );
            bytes.extend_from_slice(&chunk);
        }
        let bytes = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(&bytes);
        let value = if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(bytes).context("invalid JSON response")?
        };
        Ok((status, value))
    }

    async fn installation_token(&self) -> Result<String> {
        #[derive(Serialize)]
        struct Claims<'a> {
            iat: u64,
            exp: u64,
            iss: &'a str,
        }
        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
        let key = std::fs::read(&self.config.private_key_file).context("reading GitHub App key")?;
        let jwt = jsonwebtoken::encode(
            &jsonwebtoken::Header::new(jsonwebtoken::Algorithm::RS256),
            &Claims {
                iat: now.saturating_sub(60),
                exp: now + 540,
                iss: &self.config.app_id,
            },
            &jsonwebtoken::EncodingKey::from_rsa_pem(&key).context("invalid GitHub App key")?,
        )?;
        let url = self.checked_url(&format!(
            "{}/app/installations/{}/access_tokens",
            self.github_api, self.config.installation_id
        ))?;
        let (status, token) = self
            .send(Method::POST, url, &format!("Bearer {jwt}"), None, None)
            .await?;
        ensure!(
            status == StatusCode::CREATED,
            "App authentication returned HTTP {status}"
        );
        let token = token["token"]
            .as_str()
            .context("missing installation token")?;
        Ok(token.to_owned())
    }

    /// Complete pagination before publishing discovery, so a failed later page
    /// cannot mistakenly revoke repositories from the previous successful scan.
    pub async fn repositories(&self) -> Result<Vec<Repository>> {
        let token = self.installation_token().await?;
        let mut repos = std::collections::BTreeMap::new();
        for page in 1..=10000 {
            let mut url =
                self.checked_url(&format!("{}/installation/repositories", self.github_api))?;
            url.query_pairs_mut()
                .append_pair("per_page", "100")
                .append_pair("page", &page.to_string());
            let (status, value) = self
                .send(Method::GET, url, &format!("Bearer {token}"), None, None)
                .await?;
            ensure!(
                status == StatusCode::OK,
                "repository discovery returned HTTP {status}"
            );
            let batch: Vec<Repository> = decode(value["repositories"].clone())?;
            let done = batch.len() < 100;
            for repo in batch {
                ensure!(
                    repo.id > 0 && repo.full_name.split('/').count() == 2,
                    "invalid repository identity"
                );
                let mut scoped = self.config.clone();
                scoped.github_url = format!("https://github.com/{}", repo.full_name);
                ensure!(
                    scoped.registration_path()?.starts_with("repos/"),
                    "invalid repository name"
                );
                repos.insert(repo.id, repo);
            }
            if done {
                return Ok(repos.into_values().collect());
            }
        }
        bail!("repository discovery exceeded pagination limit")
    }

    async fn login(&mut self) -> Result<()> {
        let token = self.installation_token().await?;
        let url = self.checked_url(&format!(
            "{}/{}",
            self.github_api,
            self.config.registration_path()?
        ))?;
        let (status, registration) = self
            .send(Method::POST, url, &format!("Bearer {token}"), None, None)
            .await?;
        ensure!(
            status == StatusCode::CREATED,
            "runner registration returned HTTP {status}"
        );
        let registration = registration["token"]
            .as_str()
            .context("missing registration token")?;
        let url = self.checked_url(&format!("{}/actions/runner-registration", self.github_api))?;
        let (status, connection) = self
            .send(
                Method::POST,
                url,
                &format!("RemoteAuth {registration}"),
                Some(&json!({"url": self.config.github_url, "runner_event": "register"})),
                None,
            )
            .await?;
        ensure!(
            status.is_success(),
            "Actions connection returned HTTP {status}"
        );
        let connection: Connection = decode(connection)?;
        self.checked_url(&connection.url)?;
        ensure!(!connection.token.is_empty(), "missing Actions token");
        // Conservative refresh avoids relying on unverified JWT expiry claims.
        self.connection = Some((connection, Instant::now()));
        Ok(())
    }

    async fn service_url(&mut self, path: &str, query: &[(&str, String)]) -> Result<Url> {
        if self
            .connection
            .as_ref()
            .is_none_or(|(_, at)| at.elapsed() >= Duration::from_secs(300))
        {
            self.login().await?;
        }
        let connection = &self.connection.as_ref().unwrap().0;
        let mut url = self.checked_url(&format!(
            "{}/{}",
            connection.url.trim_end_matches('/'),
            path.trim_start_matches('/')
        ))?;
        url.query_pairs_mut()
            .append_pair("api-version", "6.0-preview")
            .extend_pairs(query.iter().map(|(k, v)| (*k, v.as_str())));
        Ok(url)
    }

    async fn admin(
        &mut self,
        method: Method,
        path: &str,
        query: &[(&str, String)],
        body: Option<Value>,
    ) -> Result<(StatusCode, Value)> {
        for attempt in 0..2 {
            let url = self.service_url(path, query).await?;
            let auth = format!("Bearer {}", self.connection.as_ref().unwrap().0.token);
            let result = self
                .send(method.clone(), url, &auth, body.as_ref(), None)
                .await?;
            if result.0 != StatusCode::UNAUTHORIZED || attempt == 1 {
                return Ok(result);
            }
            self.connection = None;
        }
        unreachable!()
    }

    pub async fn ensure_scale_set(&mut self) -> Result<()> {
        let (status, sets) = self
            .admin(
                Method::GET,
                SETS,
                &[
                    ("runnerGroupId", self.config.runner_group_id.to_string()),
                    ("name", self.config.scale_set.clone()),
                ],
                None,
            )
            .await?;
        ensure!(
            status == StatusCode::OK,
            "scale-set lookup returned HTTP {status}"
        );
        let values = sets["value"].as_array().context("missing scale-set list")?;
        ensure!(values.len() <= 1, "ambiguous scale-set name");
        let set =
            if let Some(set) = values.first() {
                set.clone()
            } else {
                let (status, set) = self.admin(Method::POST, SETS, &[], Some(json!({
                "name": self.config.scale_set, "runnerGroupId": self.config.runner_group_id,
                "labels": [{"name": self.config.scale_set, "type": "System"}],
                "RunnerSetting": {"disableUpdate": false}
            }))).await?;
                ensure!(
                    status == StatusCode::OK,
                    "creating scale set returned HTTP {status}"
                );
                set
            };
        self.scale_set_id = set["id"]
            .as_u64()
            .filter(|v| *v > 0)
            .context("invalid scale-set ID")?;
        Ok(())
    }

    pub async fn open_session(&mut self, owner: &str) -> Result<()> {
        let path = format!("{SETS}/{}/sessions", self.scale_set_id);
        let (status, session) = self
            .admin(Method::POST, &path, &[], Some(json!({"ownerName": owner})))
            .await?;
        ensure!(
            status == StatusCode::OK,
            "creating session returned HTTP {status} (another listener may own this scale set)"
        );
        self.set_session(session)
    }

    fn set_session(&mut self, value: Value) -> Result<()> {
        let session: Session = decode(value).context("invalid session response")?;
        uuid::Uuid::parse_str(&session.session_id).context("invalid session ID")?;
        self.checked_url(&session.message_queue_url)?;
        ensure!(
            !session.message_queue_access_token.is_empty(),
            "empty queue token"
        );
        self.session = Some(session);
        Ok(())
    }

    async fn refresh_session(&mut self) -> Result<()> {
        let session = self.session.as_ref().context("no active session")?;
        let path = format!(
            "{SETS}/{}/sessions/{}",
            self.scale_set_id, session.session_id
        );
        let (status, value) = self.admin(Method::PATCH, &path, &[], None).await?;
        if status == StatusCode::NOT_FOUND || status == StatusCode::CONFLICT {
            return Err(SessionLost.into());
        }
        ensure!(
            status == StatusCode::OK,
            "refreshing session returned HTTP {status}"
        );
        self.set_session(value)
    }

    // Queue token is also used for acquirejobs on the Actions service URL.
    async fn queue(
        &mut self,
        method: Method,
        suffix: Option<u64>,
        last: u64,
        capacity: Option<usize>,
        acquire: Option<Value>,
    ) -> Result<(StatusCode, Value)> {
        for attempt in 0..2 {
            let session = self.session.clone().context("no active session")?;
            let mut url = if acquire.is_some() {
                self.service_url(&format!("{SETS}/{}/acquirejobs", self.scale_set_id), &[])
                    .await?
            } else {
                self.checked_url(&session.message_queue_url)?
            };
            if let Some(id) = suffix {
                url.set_path(&format!("{}/{id}", url.path().trim_end_matches('/')));
            }
            if last > 0 {
                url.query_pairs_mut()
                    .append_pair("lastMessageId", &last.to_string());
            }
            let result = self
                .send(
                    method.clone(),
                    url,
                    &format!("Bearer {}", session.message_queue_access_token),
                    acquire.as_ref(),
                    capacity,
                )
                .await?;
            if result.0 != StatusCode::UNAUTHORIZED || attempt == 1 {
                return Ok(result);
            }
            self.refresh_session().await?;
        }
        unreachable!()
    }

    pub async fn poll(&mut self, last: u64, capacity: usize) -> Result<Option<Message>> {
        let (status, value) = self
            .queue(Method::GET, None, last, Some(capacity), None)
            .await?;
        match status {
            StatusCode::ACCEPTED => Ok(None),
            StatusCode::OK => Ok(Some(decode(value)?)),
            StatusCode::NOT_FOUND | StatusCode::CONFLICT => Err(SessionLost.into()),
            _ => bail!("queue poll returned HTTP {status}"),
        }
    }

    pub async fn acknowledge(&mut self, id: u64) -> Result<()> {
        let (status, _) = self.queue(Method::DELETE, Some(id), 0, None, None).await?;
        ensure!(
            status == StatusCode::NO_CONTENT || status == StatusCode::NOT_FOUND,
            "acknowledgment returned HTTP {status}"
        );
        Ok(())
    }

    pub async fn acquire(&mut self, ids: Vec<u64>) -> Result<()> {
        if ids.is_empty() {
            return Ok(());
        }
        let (status, _) = self
            .queue(Method::POST, None, 0, None, Some(json!(ids)))
            .await?;
        ensure!(
            status == StatusCode::OK,
            "acquiring jobs returned HTTP {status}"
        );
        Ok(())
    }

    pub async fn jit(&mut self, name: &str) -> Result<Jit> {
        let (status, value) = self
            .admin(
                Method::POST,
                &format!("{SETS}/{}/generatejitconfig", self.scale_set_id),
                &[],
                Some(json!({"name": name, "workFolder": "_work"})),
            )
            .await?;
        ensure!(
            status == StatusCode::OK,
            "JIT registration returned HTTP {status}"
        );
        let jit: Jit = decode(value)?;
        ensure!(
            jit.runner.name == name
                && jit.runner.runner_scale_set_id == self.scale_set_id
                && !jit.encoded.is_empty(),
            "JIT runner identity mismatch"
        );
        Ok(jit)
    }

    pub async fn remove_runner(&mut self, name: &str) -> Result<()> {
        let (status, value) = self
            .admin(Method::GET, RUNNERS, &[("agentName", name.into())], None)
            .await?;
        ensure!(
            status == StatusCode::OK,
            "runner lookup returned HTTP {status}"
        );
        let runners: Vec<Runner> = decode(value["value"].clone())?;
        ensure!(runners.len() <= 1, "ambiguous runner identity");
        for runner in runners {
            ensure!(
                runner.name == name && runner.runner_scale_set_id == self.scale_set_id,
                "refusing to remove a runner from another scale set"
            );
            let (status, _) = self
                .admin(
                    Method::DELETE,
                    &format!("{RUNNERS}/{}", runner.id),
                    &[],
                    None,
                )
                .await?;
            ensure!(
                status == StatusCode::NO_CONTENT || status == StatusCode::NOT_FOUND,
                "runner removal returned HTTP {status}"
            );
        }
        Ok(())
    }

    pub async fn close_session(&mut self) -> Result<()> {
        if let Some(session) = &self.session {
            let path = format!(
                "{SETS}/{}/sessions/{}",
                self.scale_set_id, session.session_id
            );
            let (status, _) = self.admin(Method::DELETE, &path, &[], None).await?;
            ensure!(
                status == StatusCode::NO_CONTENT || status == StatusCode::NOT_FOUND,
                "session deletion returned HTTP {status}"
            );
            self.session = None;
        }
        Ok(())
    }
}
