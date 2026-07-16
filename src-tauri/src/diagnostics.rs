use std::{
    fs::{File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::Path,
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager};
use zip::{write::SimpleFileOptions, CompressionMethod, ZipWriter};

const MAX_NATIVE_LOG_BYTES: usize = 256 * 1024;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticExportRequest {
    character_id: String,
    character_version: String,
    character_schema_version: u64,
    settings_summary: serde_json::Value,
    frontend_logs: serde_json::Value,
    updater_status: String,
    updater_failure_category: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticExportResult {
    file_name: String,
    location: &'static str,
}

fn redact_windows_paths(value: &str) -> String {
    let chars: Vec<char> = value.chars().collect();
    let mut output = String::with_capacity(chars.len());
    let mut index = 0;
    while index < chars.len() {
        let drive_boundary = index == 0
            || chars[index - 1].is_whitespace()
            || matches!(chars[index - 1], '"' | '\'' | '(' | '[' | '=' | ':');
        let drive_path = drive_boundary
            && index + 2 < chars.len()
            && chars[index].is_ascii_alphabetic()
            && chars[index + 1] == ':'
            && matches!(chars[index + 2], '\\' | '/')
            && (index + 3 >= chars.len() || chars[index + 3] != chars[index + 2]);
        let unc_path = index + 1 < chars.len() && chars[index] == '\\' && chars[index + 1] == '\\';
        if drive_path || unc_path {
            output.push_str(if unc_path {
                "[network path]"
            } else {
                "[local path]"
            });
            index += if unc_path { 2 } else { 3 };
            while index < chars.len()
                && !chars[index].is_whitespace()
                && !matches!(chars[index], ',' | ';' | ')' | ']' | '"')
            {
                index += 1;
            }
            continue;
        }
        output.push(chars[index]);
        index += 1;
    }
    output
}

fn redact_urls(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    let mut remaining = value;
    loop {
        let http = remaining.find("http://");
        let https = remaining.find("https://");
        let start = match (http, https) {
            (Some(left), Some(right)) => left.min(right),
            (Some(value), None) | (None, Some(value)) => value,
            (None, None) => {
                output.push_str(remaining);
                break;
            }
        };
        output.push_str(&remaining[..start]);
        let candidate_and_tail = &remaining[start..];
        let end = candidate_and_tail
            .char_indices()
            .find_map(|(index, character)| {
                (index > 0
                    && (character.is_whitespace()
                        || matches!(character, ',' | ';' | ')' | ']' | '"' | '\'')))
                .then_some(index)
            })
            .unwrap_or(candidate_and_tail.len());
        let candidate = &candidate_and_tail[..end];
        if let Ok(url) = url::Url::parse(candidate) {
            if matches!(url.scheme(), "http" | "https") {
                output.push_str(&format!(
                    "{}://{}/[redacted]",
                    url.scheme(),
                    url.host_str().unwrap_or("host")
                ));
            } else {
                output.push_str("[redacted url]");
            }
        } else {
            output.push_str("[redacted url]");
        }
        remaining = &candidate_and_tail[end..];
    }
    output
}

fn replace_case_insensitive(value: &str, needle: &str, replacement: &str) -> String {
    if needle.is_empty() {
        return value.to_string();
    }
    if !needle.is_ascii() {
        return value.replace(needle, replacement);
    }
    let lower_value = value.to_ascii_lowercase();
    let lower_needle = needle.to_ascii_lowercase();
    let mut output = String::with_capacity(value.len());
    let mut offset = 0;
    while let Some(relative) = lower_value[offset..].find(&lower_needle) {
        let start = offset + relative;
        output.push_str(&value[offset..start]);
        output.push_str(replacement);
        offset = start + needle.len();
    }
    output.push_str(&value[offset..]);
    output
}

pub fn sanitize_text(value: &str) -> String {
    let lower = value.to_ascii_lowercase();
    if lower.contains("-----begin") && lower.contains("private key-----")
        || lower.contains("tauri_signing_private_key")
        || lower.contains("access_token")
        || lower.contains("access-token")
        || lower.contains("bearer ")
        || lower.contains("password=")
        || lower.contains("password:")
    {
        return "[sensitive value redacted]".to_string();
    }

    let environment_redactions = [
        ("USERPROFILE", "[user profile]"),
        ("HOME", "[user profile]"),
        ("USERNAME", "[user name]"),
        ("USERDOMAIN", "[user domain]"),
        ("COMPUTERNAME", "[computer name]"),
    ];
    let without_identity = environment_redactions
        .iter()
        .filter_map(|(name, replacement)| {
            std::env::var(name)
                .ok()
                .filter(|item| !item.is_empty())
                .map(|item| (item, *replacement))
        })
        .fold(value.to_string(), |current, (identity, replacement)| {
            replace_case_insensitive(&current, &identity, replacement)
        });
    redact_urls(&redact_windows_paths(&without_identity))
}

fn sanitize_json(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::String(text) => *text = sanitize_text(text),
        serde_json::Value::Array(items) => items.iter_mut().for_each(sanitize_json),
        serde_json::Value::Object(map) => {
            for (key, item) in map.iter_mut() {
                let lower = key.to_ascii_lowercase();
                if lower.contains("password")
                    || lower.contains("privatekey")
                    || lower.contains("private_key")
                    || lower.contains("token")
                    || lower.contains("secret")
                {
                    *item = serde_json::Value::String("[redacted]".to_string());
                } else {
                    sanitize_json(item);
                }
            }
        }
        _ => {}
    }
}

#[cfg(windows)]
fn windows_version() -> String {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    Command::new("cmd.exe")
        .args(["/D", "/C", "ver"])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "Windows (version unavailable)".to_string())
}

#[cfg(not(windows))]
fn windows_version() -> String {
    std::env::consts::OS.to_string()
}

fn recent_native_logs(directory: &Path) -> String {
    let mut files = match std::fs::read_dir(directory) {
        Ok(entries) => entries
            .flatten()
            .filter_map(|entry| {
                let metadata = entry.metadata().ok()?;
                metadata
                    .is_file()
                    .then_some((metadata.modified().ok(), entry.path()))
            })
            .collect::<Vec<_>>(),
        Err(_) => return String::new(),
    };
    files.sort_by(|left, right| right.0.cmp(&left.0));
    let mut remaining = MAX_NATIVE_LOG_BYTES;
    let mut chunks = Vec::new();
    for (_, path) in files {
        if remaining == 0 {
            break;
        }
        let mut bytes = Vec::new();
        let Ok(mut file) = File::open(&path) else {
            continue;
        };
        let available = file.metadata().map(|value| value.len()).unwrap_or_default();
        let bytes_to_read = available.min(remaining as u64);
        if bytes_to_read == 0 {
            continue;
        }
        if file.seek(SeekFrom::End(-(bytes_to_read as i64))).is_err()
            || file.take(bytes_to_read).read_to_end(&mut bytes).is_err()
        {
            continue;
        }
        remaining = remaining.saturating_sub(bytes.len());
        let mut sanitized = String::new();
        for line in String::from_utf8_lossy(&bytes).lines() {
            sanitized.push_str(&sanitize_text(line));
            sanitized.push('\n');
        }
        chunks.push(sanitized);
    }
    chunks.reverse();
    chunks.concat()
}

fn add_zip_file(zip: &mut ZipWriter<File>, name: &str, bytes: &[u8]) -> Result<(), String> {
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
    zip.start_file(name, options)
        .map_err(|error| format!("cannot create diagnostics entry: {error}"))?;
    zip.write_all(bytes)
        .map_err(|error| format!("cannot write diagnostics entry: {error}"))
}

#[tauri::command]
pub fn open_log_directory(app: AppHandle) -> Result<(), String> {
    let directory = app
        .path()
        .app_log_dir()
        .map_err(|error| format!("cannot resolve log directory: {error}"))?;
    std::fs::create_dir_all(&directory)
        .map_err(|error| format!("cannot create log directory: {error}"))?;
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        Command::new("explorer.exe")
            .arg(&directory)
            .creation_flags(CREATE_NO_WINDOW)
            .spawn()
            .map_err(|error| format!("cannot open log directory: {error}"))?;
    }
    Ok(())
}

#[tauri::command]
pub fn export_diagnostics(
    app: AppHandle,
    request: DiagnosticExportRequest,
) -> Result<DiagnosticExportResult, String> {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or_default();
    let file_name = format!("qijiang-diagnostics-{timestamp}.zip");
    let (output_directory, location) = match app.path().download_dir() {
        Ok(directory) => (directory, "downloads"),
        Err(_) => (
            app.path()
                .app_local_data_dir()
                .map_err(|error| format!("cannot resolve diagnostics directory: {error}"))?
                .join("diagnostics"),
            "applicationData",
        ),
    };
    std::fs::create_dir_all(&output_directory)
        .map_err(|error| format!("cannot create diagnostics directory: {error}"))?;
    let output_path = output_directory.join(&file_name);
    let file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&output_path)
        .map_err(|error| format!("cannot create diagnostics archive: {error}"))?;

    let runtime = crate::updater::runtime_configuration(&app);
    let mut settings_summary = request.settings_summary;
    let mut frontend_logs = request.frontend_logs;
    sanitize_json(&mut settings_summary);
    sanitize_json(&mut frontend_logs);
    let diagnostics = serde_json::json!({
        "application": {
            "name": app.package_info().name,
            "version": app.package_info().version.to_string(),
            "identifier": app.config().identifier,
            "tauriVersion": tauri::VERSION,
            "webView2Version": tauri::webview_version().unwrap_or_else(|_| "unavailable".to_string()),
        },
        "platform": {
            "windowsVersion": windows_version(),
            "architecture": std::env::consts::ARCH,
        },
        "character": {
            "id": sanitize_text(&request.character_id),
            "version": sanitize_text(&request.character_version),
            "schemaVersion": request.character_schema_version,
        },
        "settingsSummary": settings_summary,
        "updater": {
            "status": sanitize_text(&request.updater_status),
            "failureCategory": request.updater_failure_category.map(|value| sanitize_text(&value)),
            "channel": runtime.channel,
            "endpointDomain": runtime.endpoint_domain,
            "publicKeyFingerprint": runtime.public_key_fingerprint,
            "installerSha256": option_env!("QIJIANG_INSTALLER_SHA256"),
        },
        "privacy": {
            "telemetry": false,
            "automaticallyUploaded": false,
            "pathsIncluded": false,
        },
    });

    let log_directory = app.path().app_log_dir().ok();
    let native_logs = log_directory
        .as_deref()
        .map(recent_native_logs)
        .unwrap_or_default();
    let mut zip = ZipWriter::new(file);
    let diagnostics_bytes = serde_json::to_vec_pretty(&diagnostics)
        .map_err(|error| format!("cannot serialize diagnostics: {error}"))?;
    let frontend_bytes = serde_json::to_vec_pretty(&frontend_logs)
        .map_err(|error| format!("cannot serialize frontend logs: {error}"))?;
    add_zip_file(&mut zip, "diagnostics.json", &diagnostics_bytes)?;
    add_zip_file(&mut zip, "recent-frontend-logs.json", &frontend_bytes)?;
    add_zip_file(&mut zip, "recent-native-logs.txt", native_logs.as_bytes())?;
    add_zip_file(
        &mut zip,
        "README.txt",
        "此诊断包由用户主动导出，不会自动上传。内容已按白名单生成并进行路径与秘密脱敏。\n"
            .as_bytes(),
    )?;
    zip.finish()
        .map_err(|error| format!("cannot finish diagnostics archive: {error}"))?;
    log::info!("sanitized diagnostics archive exported by user request");
    Ok(DiagnosticExportResult {
        file_name,
        location,
    })
}

#[cfg(test)]
mod tests {
    use super::{
        recent_native_logs, replace_case_insensitive, sanitize_json, sanitize_text,
        MAX_NATIVE_LOG_BYTES,
    };

    #[test]
    fn diagnostic_text_removes_paths_urls_and_signing_secrets() {
        assert!(!sanitize_text("C:\\Users\\name\\file.log").contains("name"));
        assert_eq!(
            sanitize_text("https://updates.example.org/latest.json?token=secret"),
            "https://updates.example.org/[redacted]"
        );
        assert_eq!(
            sanitize_text("endpoint=https://updates.example.org/latest.json?token=secret"),
            "endpoint=https://updates.example.org/[redacted]"
        );
        assert_eq!(
            sanitize_text("TAURI_SIGNING_PRIVATE_KEY_PASSWORD=secret"),
            "[sensitive value redacted]"
        );
        assert_eq!(
            replace_case_insensitive("Owner=Alice; owner=ALICE", "alice", "[user]"),
            "Owner=[user]; owner=[user]"
        );
    }

    #[test]
    fn diagnostic_json_redacts_secret_named_fields() {
        let access_token_key = ["access", "Token"].concat();
        let access_token_value = ["secret", "-value"].concat();
        let password_key = ["pass", "word"].concat();
        let password_value = ["also", "-secret"].concat();
        let mut value = serde_json::json!({ "safe": true, "nested": {} });
        value[access_token_key.as_str()] = serde_json::Value::String(access_token_value);
        value["nested"][password_key.as_str()] = serde_json::Value::String(password_value);
        sanitize_json(&mut value);
        assert_eq!(value["safe"], true);
        assert_eq!(value["accessToken"], "[redacted]");
        assert_eq!(value["nested"]["password"], "[redacted]");
        assert!(!value.to_string().contains("secret-value"));
    }

    #[test]
    fn diagnostic_logs_keep_the_recent_tail_of_large_files() {
        let directory =
            std::env::temp_dir().join(format!("qijiang-diagnostic-tail-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("latest.log");
        let mut bytes = vec![b'x'; MAX_NATIVE_LOG_BYTES + 1024];
        bytes.extend_from_slice(b"\nRECENT_MARKER\n");
        std::fs::write(path, bytes).unwrap();

        let logs = recent_native_logs(&directory);
        assert!(logs.contains("RECENT_MARKER"));
        assert!(logs.len() <= MAX_NATIVE_LOG_BYTES + 32);
        std::fs::remove_dir_all(directory).unwrap();
    }
}
