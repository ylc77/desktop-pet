use std::{sync::Mutex, time::Duration};

use serde::Serialize;
use sha2::{Digest, Sha256};
use tauri::{ipc::Channel, AppHandle};
use tauri_plugin_updater::{Update, UpdaterExt};
use url::Url;

const DEFAULT_CHANNEL: &str = "stable";
const UPDATE_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeConfiguration {
    pub(crate) configured: bool,
    status: &'static str,
    application_name: String,
    current_version: String,
    pub(crate) channel: String,
    pub(crate) endpoint_domain: Option<String>,
    pub(crate) public_key_fingerprint: Option<String>,
    install_mode: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateMetadata {
    current_version: String,
    version: String,
    notes: Option<String>,
    published_at: Option<String>,
    content_length: Option<u64>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "event", content = "data", rename_all = "camelCase")]
pub enum DownloadEvent {
    Started {
        #[serde(rename = "contentLength")]
        content_length: Option<u64>,
    },
    Progress {
        #[serde(rename = "chunkLength")]
        chunk_length: usize,
        #[serde(rename = "contentLength")]
        content_length: Option<u64>,
    },
    Finished,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandError {
    category: &'static str,
    message: &'static str,
}

impl CommandError {
    fn new(category: &'static str, message: &'static str) -> Self {
        Self { category, message }
    }

    fn busy() -> Self {
        Self::new("busy", "已有更新任务正在进行")
    }

    fn from_updater(error: &tauri_plugin_updater::Error, operation: Operation) -> Self {
        use tauri_plugin_updater::Error;
        match error {
            Error::Reqwest(value) if value.is_timeout() => Self::new("timeout", "更新服务响应超时"),
            Error::Reqwest(_) => Self::new("offline", "无法连接更新服务"),
            Error::Network(value) if value.contains("404") => {
                Self::new("endpointNotFound", "更新信息或更新包不存在")
            }
            Error::Network(_) => Self::new("downloadInterrupted", "更新包下载中断"),
            Error::Minisign(_) | Error::Base64(_) | Error::SignatureUtf8(_) => {
                Self::new("invalidSignature", "更新包签名验证失败")
            }
            Error::Serialization(_)
            | Error::Semver(_)
            | Error::ReleaseNotFound
            | Error::TargetNotFound(_)
            | Error::TargetsNotFound(_)
            | Error::UrlParse(_) => Self::new("invalidMetadata", "更新信息格式无效"),
            Error::UnsupportedArch | Error::UnsupportedOs => {
                Self::new("unsupported", "当前平台不支持应用更新")
            }
            Error::Io(value) if value.kind() == std::io::ErrorKind::PermissionDenied => {
                Self::new("permissionDenied", "系统拒绝了更新操作")
            }
            Error::AuthenticationFailed => {
                Self::new("permissionDenied", "更新安装授权失败或已取消")
            }
            Error::InsecureTransportProtocol => {
                Self::new("invalidMetadata", "生产更新地址必须使用 HTTPS")
            }
            _ if matches!(operation, Operation::Install) => {
                Self::new("installFailed", "更新安装失败")
            }
            _ => Self::new("unknown", "更新操作失败，请查看脱敏日志"),
        }
    }
}

#[derive(Clone, Copy)]
enum Operation {
    Check,
    Download,
    Install,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum NativePhase {
    #[default]
    Idle,
    Checking,
    Available,
    Downloading,
    ReadyToInstall,
    Installing,
    Restarting,
}

struct DownloadedUpdate {
    update: Update,
    bytes: Vec<u8>,
}

#[derive(Default)]
struct InnerState {
    phase: NativePhase,
    pending: Option<Update>,
    downloaded: Option<DownloadedUpdate>,
}

#[derive(Default)]
pub struct UpdaterState(Mutex<InnerState>);

fn check_is_blocked(phase: NativePhase) -> bool {
    matches!(
        phase,
        NativePhase::Checking
            | NativePhase::Downloading
            | NativePhase::ReadyToInstall
            | NativePhase::Installing
            | NativePhase::Restarting
    )
}

fn configured_values() -> (&'static str, &'static str, &'static str) {
    (
        option_env!("QIJIANG_UPDATER_ENDPOINT").unwrap_or(""),
        option_env!("QIJIANG_UPDATER_PUBLIC_KEY").unwrap_or(""),
        option_env!("QIJIANG_UPDATER_CHANNEL").unwrap_or(DEFAULT_CHANNEL),
    )
}

fn public_key_fingerprint(public_key: &str) -> String {
    let digest = Sha256::digest(public_key.trim().as_bytes());
    digest.iter().map(|byte| format!("{byte:02X}")).collect()
}

fn endpoint_is_allowed(url: &Url) -> bool {
    let Some(host) = url.host_str() else {
        return false;
    };
    let host = host.to_ascii_lowercase();
    let reserved_hosts = ["example.com", "example.org", "example.net", "localhost"];
    let reserved_suffixes = [
        ".example.com",
        ".example.org",
        ".example.net",
        ".invalid",
        ".example",
        ".test",
        ".localhost",
        ".local",
    ];
    url.scheme() == "https"
        && url.username().is_empty()
        && url.password().is_none()
        && url.query().is_none()
        && url.fragment().is_none()
        && !host.is_empty()
        && !reserved_hosts.contains(&host.as_str())
        && !reserved_suffixes
            .iter()
            .any(|suffix| host.ends_with(suffix))
        && host.parse::<std::net::IpAddr>().is_err()
}

fn resolve_configuration(
    application_name: String,
    current_version: String,
    endpoint: &str,
    public_key: &str,
    channel: &str,
) -> RuntimeConfiguration {
    let parsed_endpoint = Url::parse(endpoint.trim()).ok();
    let allowed_endpoint = parsed_endpoint
        .as_ref()
        .filter(|url| endpoint_is_allowed(url));
    let valid_channel = matches!(channel, "beta" | "stable");
    let configured = allowed_endpoint.is_some() && !public_key.trim().is_empty() && valid_channel;
    RuntimeConfiguration {
        configured,
        status: if configured {
            "configured"
        } else {
            "notConfigured"
        },
        application_name,
        current_version,
        channel: if valid_channel {
            channel.to_string()
        } else {
            DEFAULT_CHANNEL.to_string()
        },
        endpoint_domain: allowed_endpoint
            .and_then(|url| url.host_str())
            .map(ToOwned::to_owned),
        public_key_fingerprint: (!public_key.trim().is_empty())
            .then(|| public_key_fingerprint(public_key)),
        install_mode: "passive",
    }
}

pub fn runtime_configuration(app: &AppHandle) -> RuntimeConfiguration {
    let (endpoint, public_key, channel) = configured_values();
    resolve_configuration(
        app.package_info().name.clone(),
        app.package_info().version.to_string(),
        endpoint,
        public_key,
        channel,
    )
}

#[tauri::command]
pub fn get_updater_configuration(app: AppHandle) -> RuntimeConfiguration {
    runtime_configuration(&app)
}

fn updater_builder(app: &AppHandle) -> Result<tauri_plugin_updater::Updater, CommandError> {
    let (endpoint, public_key, _) = configured_values();
    let parsed = Url::parse(endpoint.trim())
        .ok()
        .filter(endpoint_is_allowed)
        .ok_or_else(|| CommandError::new("notConfigured", "更新服务尚未配置"))?;
    if public_key.trim().is_empty() {
        return Err(CommandError::new("notConfigured", "更新服务尚未配置"));
    }
    let app_handle = app.clone();
    app.updater_builder()
        .endpoints(vec![parsed])
        .map_err(|error| CommandError::from_updater(&error, Operation::Check))?
        .pubkey(public_key.trim())
        .timeout(UPDATE_TIMEOUT)
        .on_before_exit(move || {
            log::info!("updater is handing control to the Windows passive installer");
            log::logger().flush();
            app_handle.cleanup_before_exit();
        })
        .build()
        .map_err(|error| CommandError::from_updater(&error, Operation::Check))
}

fn metadata_size(update: &Update) -> Option<u64> {
    update
        .raw_json
        .get("platforms")
        .and_then(|platforms| platforms.get(&update.target))
        .and_then(|platform| platform.get("size"))
        .and_then(serde_json::Value::as_u64)
        .or_else(|| {
            update
                .raw_json
                .get("size")
                .and_then(serde_json::Value::as_u64)
        })
}

#[tauri::command]
pub async fn check_for_update(
    app: AppHandle,
    state: tauri::State<'_, UpdaterState>,
) -> Result<Option<UpdateMetadata>, CommandError> {
    if !runtime_configuration(&app).configured {
        return Err(CommandError::new("notConfigured", "更新服务尚未配置"));
    }
    {
        let mut inner = state.0.lock().map_err(|_| CommandError::busy())?;
        if check_is_blocked(inner.phase) {
            return Err(CommandError::busy());
        }
        inner.phase = NativePhase::Checking;
        inner.pending = None;
        inner.downloaded = None;
    }

    let result = match updater_builder(&app) {
        Ok(updater) => updater.check().await,
        Err(error) => {
            state.0.lock().map_err(|_| CommandError::busy())?.phase = NativePhase::Idle;
            return Err(error);
        }
    };
    match result {
        Ok(update) => {
            let metadata = update.as_ref().map(|candidate| UpdateMetadata {
                current_version: candidate.current_version.clone(),
                version: candidate.version.clone(),
                notes: candidate.body.clone(),
                published_at: candidate.date.map(|date| date.to_string()),
                content_length: metadata_size(candidate),
            });
            let mut inner = state.0.lock().map_err(|_| CommandError::busy())?;
            inner.phase = if update.is_some() {
                NativePhase::Available
            } else {
                NativePhase::Idle
            };
            inner.pending = update;
            Ok(metadata)
        }
        Err(error) => {
            state.0.lock().map_err(|_| CommandError::busy())?.phase = NativePhase::Idle;
            log::warn!(
                "updater check failed (category only): {}",
                CommandError::from_updater(&error, Operation::Check).category
            );
            Err(CommandError::from_updater(&error, Operation::Check))
        }
    }
}

#[tauri::command]
pub async fn download_update(
    state: tauri::State<'_, UpdaterState>,
    on_event: Channel<DownloadEvent>,
) -> Result<(), CommandError> {
    let update = {
        let mut inner = state.0.lock().map_err(|_| CommandError::busy())?;
        if !matches!(inner.phase, NativePhase::Available) {
            return Err(CommandError::busy());
        }
        let update = inner
            .pending
            .take()
            .ok_or_else(|| CommandError::new("busy", "当前没有可下载的更新"))?;
        inner.phase = NativePhase::Downloading;
        update
    };

    let retry = update.clone();
    let mut started = false;
    let result = update
        .download(
            |chunk_length, content_length| {
                if !started {
                    started = true;
                    let _ = on_event.send(DownloadEvent::Started { content_length });
                }
                let _ = on_event.send(DownloadEvent::Progress {
                    chunk_length,
                    content_length,
                });
            },
            || {
                let _ = on_event.send(DownloadEvent::Finished);
            },
        )
        .await;

    match result {
        Ok(bytes) => {
            let mut inner = state.0.lock().map_err(|_| CommandError::busy())?;
            inner.phase = NativePhase::ReadyToInstall;
            inner.downloaded = Some(DownloadedUpdate { update, bytes });
            Ok(())
        }
        Err(error) => {
            let mut inner = state.0.lock().map_err(|_| CommandError::busy())?;
            inner.phase = NativePhase::Available;
            inner.pending = Some(retry);
            log::warn!(
                "updater download failed (category only): {}",
                CommandError::from_updater(&error, Operation::Download).category
            );
            Err(CommandError::from_updater(&error, Operation::Download))
        }
    }
}

#[tauri::command]
pub fn install_update(state: tauri::State<'_, UpdaterState>) -> Result<(), CommandError> {
    let downloaded = {
        let mut inner = state.0.lock().map_err(|_| CommandError::busy())?;
        if !matches!(inner.phase, NativePhase::ReadyToInstall) {
            return Err(CommandError::new("busy", "更新包尚未准备完成"));
        }
        let downloaded = inner
            .downloaded
            .take()
            .ok_or_else(|| CommandError::new("busy", "更新包尚未准备完成"))?;
        inner.phase = NativePhase::Installing;
        downloaded
    };
    match downloaded.update.install(&downloaded.bytes) {
        Ok(()) => {
            state.0.lock().map_err(|_| CommandError::busy())?.phase = NativePhase::Restarting;
            Ok(())
        }
        Err(error) => {
            let mut inner = state.0.lock().map_err(|_| CommandError::busy())?;
            inner.phase = NativePhase::ReadyToInstall;
            inner.downloaded = Some(downloaded);
            log::warn!(
                "updater install failed (category only): {}",
                CommandError::from_updater(&error, Operation::Install).category
            );
            Err(CommandError::from_updater(&error, Operation::Install))
        }
    }
}

#[tauri::command]
pub fn cancel_pending_update(state: tauri::State<'_, UpdaterState>) -> Result<(), CommandError> {
    let mut inner = state.0.lock().map_err(|_| CommandError::busy())?;
    if matches!(
        inner.phase,
        NativePhase::Checking
            | NativePhase::Downloading
            | NativePhase::Installing
            | NativePhase::Restarting
    ) {
        return Err(CommandError::busy());
    }
    inner.pending = None;
    inner.downloaded = None;
    inner.phase = NativePhase::Idle;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        check_is_blocked, endpoint_is_allowed, public_key_fingerprint, resolve_configuration,
        NativePhase,
    };
    use url::Url;

    #[test]
    fn production_endpoints_require_real_https_hosts_without_credentials() {
        assert!(endpoint_is_allowed(
            &Url::parse("https://updates.qijiang-desktop-pet.com/beta/latest.json").unwrap()
        ));
        for value in [
            "http://updates.example.org/latest.json",
            "https://example.invalid/latest.json",
            "https://localhost/latest.json",
            "https://token@example.org/latest.json",
            "https://updates.example.org/latest.json?token=secret",
            "https://updates.example.org/latest.json#fragment",
            "https://updates.example.org/latest.json",
            "https://updates.local/latest.json",
            "https://203.0.113.1/latest.json",
        ] {
            assert!(!endpoint_is_allowed(&Url::parse(value).unwrap()));
        }
    }

    #[test]
    fn missing_or_partial_runtime_configuration_stays_not_configured() {
        for (endpoint, key) in [
            ("", ""),
            ("https://updates.qijiang-desktop-pet.com/latest.json", ""),
            ("", "public-key"),
            ("https://example.invalid/latest.json", "public-key"),
        ] {
            let result =
                resolve_configuration("七酱桌宠".into(), "0.1.0".into(), endpoint, key, "beta");
            assert!(!result.configured);
            assert_eq!(result.status, "notConfigured");
        }
    }

    #[test]
    fn configured_runtime_exposes_only_domain_and_public_fingerprint() {
        let result = resolve_configuration(
            "七酱桌宠".into(),
            "0.1.0".into(),
            "https://updates.qijiang-desktop-pet.com/private/latest.json",
            "public-key-content",
            "beta",
        );
        assert!(result.configured);
        assert_eq!(
            result.endpoint_domain.as_deref(),
            Some("updates.qijiang-desktop-pet.com")
        );
        assert_eq!(result.public_key_fingerprint.as_ref().unwrap().len(), 64);
        assert!(!format!("{:?}", result).contains("/private/"));
        assert_eq!(public_key_fingerprint("public-key-content").len(), 64);
    }

    #[test]
    fn native_phase_defaults_to_idle() {
        assert_eq!(NativePhase::default(), NativePhase::Idle);
    }

    #[test]
    fn downloaded_update_cannot_be_discarded_by_another_check() {
        assert!(check_is_blocked(NativePhase::ReadyToInstall));
        assert!(!check_is_blocked(NativePhase::Available));
        assert!(!check_is_blocked(NativePhase::Idle));
    }
}
