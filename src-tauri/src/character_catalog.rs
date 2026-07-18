use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{HashMap, HashSet},
    fs::{self, File, OpenOptions},
    io::{BufReader, Read, Write},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};
use tauri::{AppHandle, Emitter, Manager, Runtime, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_dialog::DialogExt;
use zip::ZipArchive;

const CHARACTER_DIRECTORY: &str = "characters";
const MAX_ARCHIVE_BYTES: u64 = 512 * 1024 * 1024;
const MAX_EXTRACTED_BYTES: u64 = 512 * 1024 * 1024;
const MAX_ENTRY_BYTES: u64 = 16 * 1024 * 1024;
const MAX_ENTRIES: usize = 2_500;
const MAX_FRAMES_PER_ANIMATION: usize = 240;
const MAX_CANVAS_EDGE: u32 = 4_096;
const MAX_DECODED_FRAME_PIXELS: u64 = 256 * 1024 * 1024;
const MAX_JSON_BYTES: u64 = 1024 * 1024;
const MAX_SELECTION_REQUEST_LIFETIME_MS: u64 = 120_000;
const MAX_PENDING_SELECTIONS: usize = 32;
const BUNDLED_CHARACTER_INDEX_JSON: &str = include_str!("../../public/characters/index.json");
const TRANSACTION_PREFIX: &str = ".transaction-";

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CharacterSummary {
    id: String,
    name: String,
    version: String,
    author: String,
    license: String,
    source: &'static str,
    valid: bool,
    errors: Vec<String>,
    preview_path: Option<String>,
    icon_path: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LoadedCharacterPackage {
    manifest: Value,
    frames: HashMap<String, Vec<String>>,
    preview_path: Option<String>,
    icon_path: Option<String>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct InstallTransaction {
    id: String,
    staging_name: String,
    backup_name: Option<String>,
}

#[derive(Clone, Default)]
pub struct CharacterCatalogLock(Arc<Mutex<()>>);

#[derive(Default)]
struct NativeCharacterSelection {
    initialized: bool,
    active_id: Option<String>,
    activation_generation: u64,
    pending: HashMap<String, PendingCharacterSelection>,
}

#[derive(Clone)]
struct PendingCharacterSelection {
    id: String,
    expires_at_ms: u64,
    authorized_generation: Option<u64>,
}

#[derive(Clone, Default)]
pub struct ActiveCharacterState(Arc<Mutex<NativeCharacterSelection>>);

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CharacterManifest {
    schema_version: u32,
    id: String,
    name: String,
    version: String,
    author: String,
    license: String,
    default_scale: f64,
    frame_size: FrameSize,
    anchor: Point,
    #[serde(default)]
    hitbox: Option<Hitbox>,
    #[serde(default)]
    visual: Option<Visual>,
    #[serde(default)]
    preview: Option<String>,
    #[serde(default)]
    icon: Option<String>,
    animations: HashMap<String, AnimationDefinition>,
    #[serde(default)]
    interactions: Option<Interactions>,
    #[serde(default)]
    skins: Option<HashMap<String, SkinDefinition>>,
}

#[derive(Clone, Deserialize)]
struct FrameSize {
    width: u32,
    height: u32,
}

#[derive(Clone, Deserialize)]
struct Point {
    x: f64,
    y: f64,
}

#[derive(Clone, Deserialize)]
struct Hitbox {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Visual {
    #[serde(default)]
    drop_shadow: Option<bool>,
    #[serde(default)]
    ground_shadow: Option<GroundShadow>,
}

#[derive(Clone, Deserialize)]
struct GroundShadow {
    enabled: bool,
    #[serde(default)]
    width: Option<f64>,
    #[serde(default)]
    height: Option<f64>,
    #[serde(default)]
    opacity: Option<f64>,
    #[serde(default)]
    blur: Option<f64>,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AnimationDefinition {
    path: String,
    fps: f64,
    #[serde(rename = "loop")]
    loop_: bool,
    #[serde(default)]
    return_to: Option<String>,
    #[serde(default)]
    interruptible: Option<bool>,
    #[serde(default)]
    priority: Option<i64>,
    #[serde(default)]
    weight: Option<f64>,
    #[serde(default)]
    min_delay_ms: Option<i64>,
    #[serde(default)]
    max_delay_ms: Option<i64>,
    #[serde(default)]
    min_duration_ms: Option<i64>,
    #[serde(default)]
    max_duration_ms: Option<i64>,
    #[serde(default)]
    anticipation: Option<String>,
    #[serde(default)]
    recovery: Option<String>,
    #[serde(default)]
    offset_x: Option<f64>,
    #[serde(default)]
    offset_y: Option<f64>,
    #[serde(default)]
    scale: Option<f64>,
    #[serde(default)]
    flip_x_allowed: Option<bool>,
    #[serde(default)]
    movement: Option<Movement>,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Movement {
    speed: f64,
    #[serde(default)]
    acceleration: Option<f64>,
    #[serde(default)]
    deceleration: Option<f64>,
    #[serde(default)]
    edge_padding: Option<f64>,
    #[serde(default)]
    direction: Option<String>,
    #[serde(default)]
    reverse_to: Option<String>,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Interactions {
    #[serde(default)]
    click: Option<String>,
    #[serde(default)]
    double_click: Option<String>,
    #[serde(default)]
    hover: Option<String>,
    #[serde(default)]
    drag: Option<String>,
    #[serde(default)]
    land: Option<String>,
    #[serde(default)]
    cooldown_ms: Option<i64>,
}

#[derive(Clone, Deserialize)]
struct SkinDefinition {
    name: String,
    #[serde(default)]
    filter: Option<String>,
}

#[derive(Deserialize)]
struct FrameIndex {
    animations: HashMap<String, Vec<String>>,
}

struct ValidatedPackage {
    manifest_value: Value,
    manifest: CharacterManifest,
    frames: HashMap<String, Vec<String>>,
}

struct PngInfo {
    width: u32,
    height: u32,
    color_type: png::ColorType,
    bit_depth: png::BitDepth,
    has_transparency: bool,
}

fn character_root<R: Runtime>(app: &AppHandle<R>) -> Result<PathBuf, String> {
    app.path()
        .app_local_data_dir()
        .map(|directory| directory.join(CHARACTER_DIRECTORY))
        .map_err(|error| format!("无法解析本地角色目录: {error}"))
}

fn now_token() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_nanos())
        .unwrap_or_default();
    format!("{}-{nanos}", std::process::id())
}

fn unix_time_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_millis().min(u128::from(u64::MAX)) as u64)
        .unwrap_or_default()
}

fn is_selection_deadline_valid(expires_at_ms: u64, now_ms: u64) -> bool {
    expires_at_ms > now_ms
        && expires_at_ms <= now_ms.saturating_add(MAX_SELECTION_REQUEST_LIFETIME_MS)
}

fn is_character_id(value: &str) -> bool {
    let mut characters = value.chars();
    let Some(first) = characters.next() else {
        return false;
    };
    (first.is_ascii_lowercase() || first.is_ascii_digit() || first == '_')
        && characters.all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || character == '_'
                || character == '-'
        })
}

fn is_request_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct CharacterSelectionRequest {
    id: String,
    source: String,
    request_id: String,
    expires_at_ms: u64,
}

fn is_animation_state(value: &str) -> bool {
    let mut characters = value.chars();
    let Some(first) = characters.next() else {
        return false;
    };
    first.is_ascii_lowercase()
        && characters.all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || character == '_'
                || character == '-'
        })
}

fn is_reserved_windows_component(component: &str) -> bool {
    let base = component
        .split('.')
        .next()
        .unwrap_or(component)
        .to_ascii_uppercase();
    matches!(base.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || (base.len() == 4
            && (base.starts_with("COM") || base.starts_with("LPT"))
            && matches!(base.as_bytes()[3], b'1'..=b'9'))
}

fn safe_relative_path(value: &str) -> Result<PathBuf, String> {
    if value.is_empty() || value.len() > 240 {
        return Err("路径为空或过长".into());
    }
    if value.starts_with('/') || value.starts_with("//") || value.contains('\\') {
        return Err("路径必须使用包内正斜杠相对路径".into());
    }
    let mut path = PathBuf::new();
    for component in value.split('/') {
        if component.is_empty() || component == "." || component == ".." {
            return Err("路径包含空段、点段或父目录".into());
        }
        if component.ends_with('.')
            || component.ends_with(' ')
            || component.chars().any(|character| {
                character.is_control()
                    || matches!(character, '<' | '>' | ':' | '"' | '|' | '?' | '*')
            })
            || is_reserved_windows_component(component)
        {
            return Err(format!("Windows 路径段无效: {component}"));
        }
        path.push(component);
    }
    Ok(path)
}

fn finite_in_range(value: f64, minimum: f64, maximum: f64) -> bool {
    value.is_finite() && value >= minimum && value <= maximum
}

fn validate_optional_state(name: &str, value: Option<&String>) -> Result<(), String> {
    if let Some(value) = value {
        if !is_animation_state(value) {
            return Err(format!("{name} 动作名无效"));
        }
    }
    Ok(())
}

fn validate_manifest(manifest: &CharacterManifest) -> Result<(), String> {
    if manifest.schema_version != 1 {
        return Err(format!("不支持 schemaVersion {}", manifest.schema_version));
    }
    if !is_character_id(&manifest.id) {
        return Err("角色 ID 无效".into());
    }
    for (name, value) in [
        ("name", &manifest.name),
        ("version", &manifest.version),
        ("author", &manifest.author),
        ("license", &manifest.license),
    ] {
        if value.trim().is_empty() {
            return Err(format!("{name} 不能为空"));
        }
    }
    if !finite_in_range(manifest.default_scale, f64::MIN_POSITIVE, 4.0) {
        return Err("defaultScale 必须为 0-4 的正数".into());
    }
    if !(16..=MAX_CANVAS_EDGE).contains(&manifest.frame_size.width)
        || !(16..=MAX_CANVAS_EDGE).contains(&manifest.frame_size.height)
    {
        return Err("frameSize 超出 16-4096".into());
    }
    if !finite_in_range(manifest.anchor.x, 0.0, 1.0)
        || !finite_in_range(manifest.anchor.y, 0.0, 1.0)
    {
        return Err("anchor 必须位于 0-1".into());
    }
    if let Some(hitbox) = &manifest.hitbox {
        if !finite_in_range(hitbox.x, 0.0, 1.0)
            || !finite_in_range(hitbox.y, 0.0, 1.0)
            || !finite_in_range(hitbox.width, f64::MIN_POSITIVE, 1.0)
            || !finite_in_range(hitbox.height, f64::MIN_POSITIVE, 1.0)
            || hitbox.x + hitbox.width > 1.0
            || hitbox.y + hitbox.height > 1.0
        {
            return Err("hitbox 必须位于画布内".into());
        }
    }
    if let Some(visual) = &manifest.visual {
        let _ = visual.drop_shadow;
        if let Some(shadow) = &visual.ground_shadow {
            let _ = shadow.enabled;
            if shadow
                .width
                .is_some_and(|value| !finite_in_range(value, f64::MIN_POSITIVE, 2.0))
                || shadow
                    .height
                    .is_some_and(|value| !finite_in_range(value, f64::MIN_POSITIVE, 1.0))
                || shadow
                    .opacity
                    .is_some_and(|value| !finite_in_range(value, 0.0, 0.5))
                || shadow
                    .blur
                    .is_some_and(|value| !finite_in_range(value, 0.0, 32.0))
            {
                return Err("visual.groundShadow 参数越界".into());
            }
        }
    }
    for (field, value) in [
        ("preview", manifest.preview.as_ref()),
        ("icon", manifest.icon.as_ref()),
    ] {
        if let Some(value) = value {
            safe_relative_path(value).map_err(|error| format!("{field}: {error}"))?;
        }
    }
    if !manifest.animations.contains_key("idle") {
        return Err("必须提供 idle 动画".into());
    }
    for (state, animation) in &manifest.animations {
        if !is_animation_state(state) {
            return Err(format!("动作名无效: {state}"));
        }
        safe_relative_path(&animation.path).map_err(|error| format!("{state}.path: {error}"))?;
        if !finite_in_range(animation.fps, 1.0, 60.0) {
            return Err(format!("{state}.fps 必须为 1-60"));
        }
        let _ = animation.loop_;
        let _ = animation.interruptible;
        let _ = animation.flip_x_allowed;
        validate_optional_state(&format!("{state}.returnTo"), animation.return_to.as_ref())?;
        validate_optional_state(
            &format!("{state}.anticipation"),
            animation.anticipation.as_ref(),
        )?;
        validate_optional_state(&format!("{state}.recovery"), animation.recovery.as_ref())?;
        if animation
            .priority
            .is_some_and(|value| !(0..=1_000).contains(&value))
        {
            return Err(format!("{state}.priority 越界"));
        }
        if animation
            .weight
            .is_some_and(|value| !finite_in_range(value, 0.0, 1_000.0))
        {
            return Err(format!("{state}.weight 越界"));
        }
        for (name, value) in [
            ("minDelayMs", animation.min_delay_ms),
            ("maxDelayMs", animation.max_delay_ms),
        ] {
            if value.is_some_and(|value| value < 0) {
                return Err(format!("{state}.{name} 不能为负数"));
            }
        }
        if animation
            .min_delay_ms
            .zip(animation.max_delay_ms)
            .is_some_and(|(min, max)| min > max)
        {
            return Err(format!("{state}.minDelayMs 不能大于 maxDelayMs"));
        }
        for (name, value) in [
            ("minDurationMs", animation.min_duration_ms),
            ("maxDurationMs", animation.max_duration_ms),
        ] {
            if value.is_some_and(|value| !(100..=120_000).contains(&value)) {
                return Err(format!("{state}.{name} 超出 100-120000"));
            }
        }
        if animation
            .min_duration_ms
            .zip(animation.max_duration_ms)
            .is_some_and(|(min, max)| min > max)
        {
            return Err(format!("{state}.minDurationMs 不能大于 maxDurationMs"));
        }
        if animation.offset_x.is_some_and(|value| !value.is_finite())
            || animation.offset_y.is_some_and(|value| !value.is_finite())
            || animation
                .scale
                .is_some_and(|value| !finite_in_range(value, f64::MIN_POSITIVE, 10.0))
        {
            return Err(format!("{state} 的 offset/scale 无效"));
        }
        if let Some(movement) = &animation.movement {
            if !finite_in_range(movement.speed, f64::MIN_POSITIVE, 500.0)
                || movement
                    .acceleration
                    .is_some_and(|value| !finite_in_range(value, f64::MIN_POSITIVE, 2_000.0))
                || movement
                    .deceleration
                    .is_some_and(|value| !finite_in_range(value, f64::MIN_POSITIVE, 2_000.0))
                || movement
                    .edge_padding
                    .is_some_and(|value| !finite_in_range(value, 0.0, 512.0))
                || movement
                    .direction
                    .as_deref()
                    .is_some_and(|value| value != "left" && value != "right")
            {
                return Err(format!("{state}.movement 参数无效"));
            }
            validate_optional_state(
                &format!("{state}.movement.reverseTo"),
                movement.reverse_to.as_ref(),
            )?;
        }
    }
    if let Some(interactions) = &manifest.interactions {
        for (name, value) in [
            ("click", interactions.click.as_ref()),
            ("doubleClick", interactions.double_click.as_ref()),
            ("hover", interactions.hover.as_ref()),
            ("drag", interactions.drag.as_ref()),
            ("land", interactions.land.as_ref()),
        ] {
            validate_optional_state(&format!("interactions.{name}"), value)?;
        }
        if interactions.cooldown_ms.is_some_and(|value| value < 0) {
            return Err("interactions.cooldownMs 不能为负数".into());
        }
    }
    if let Some(skins) = &manifest.skins {
        for (id, skin) in skins {
            if id.trim().is_empty() || skin.name.trim().is_empty() {
                return Err("skins 的 ID 和名称不能为空".into());
            }
            let _ = &skin.filter;
        }
    }
    Ok(())
}

fn read_json_value(path: &Path) -> Result<Value, String> {
    let metadata = fs::metadata(path).map_err(|_| "缺少必需 JSON 文件".to_string())?;
    if !metadata.is_file() || metadata.len() > MAX_JSON_BYTES {
        return Err("JSON 文件不是普通文件或超过 1 MiB".into());
    }
    let bytes = fs::read(path).map_err(|_| "JSON 文件无法读取".to_string())?;
    serde_json::from_slice(&bytes).map_err(|error| format!("JSON 无法解析: {error}"))
}

fn inspect_png(path: &Path, maximum_bytes: u64) -> Result<PngInfo, String> {
    let metadata = fs::metadata(path).map_err(|_| "PNG 文件不存在".to_string())?;
    if !metadata.is_file() || metadata.len() > maximum_bytes {
        return Err("PNG 不是普通文件或文件过大".into());
    }
    let file = File::open(path).map_err(|_| "PNG 文件无法读取".to_string())?;
    let decoder = png::Decoder::new(BufReader::new(file));
    let mut reader = decoder
        .read_info()
        .map_err(|error| format!("PNG 头无效: {error}"))?;
    let header = reader.info();
    if header.width == 0
        || header.height == 0
        || header.width > MAX_CANVAS_EDGE
        || header.height > MAX_CANVAS_EDGE
    {
        return Err("PNG 画布尺寸无效或超过 4096".into());
    }
    let buffer_size = reader
        .output_buffer_size()
        .ok_or_else(|| "PNG 解码缓冲区过大".to_string())?;
    let mut buffer = vec![0; buffer_size];
    let output = reader
        .next_frame(&mut buffer)
        .map_err(|error| format!("PNG 数据损坏: {error}"))?;
    let bytes = &buffer[..output.buffer_size()];
    let has_transparency = match (output.color_type, output.bit_depth) {
        (png::ColorType::Rgba, png::BitDepth::Eight) => {
            bytes.chunks_exact(4).any(|pixel| pixel[3] < u8::MAX)
        }
        (png::ColorType::Rgba, png::BitDepth::Sixteen) => bytes
            .chunks_exact(8)
            .any(|pixel| u16::from_be_bytes([pixel[6], pixel[7]]) < u16::MAX),
        _ => false,
    };
    Ok(PngInfo {
        width: output.width,
        height: output.height,
        color_type: output.color_type,
        bit_depth: output.bit_depth,
        has_transparency,
    })
}

fn resolve_existing_file(root: &Path, relative: &str) -> Result<PathBuf, String> {
    let relative_path = safe_relative_path(relative)?;
    let candidate = root.join(relative_path);
    let canonical_root = fs::canonicalize(root).map_err(|_| "角色目录无法解析".to_string())?;
    let canonical = fs::canonicalize(&candidate).map_err(|_| format!("资源不存在: {relative}"))?;
    if !canonical.starts_with(&canonical_root) || !canonical.is_file() {
        return Err(format!("资源越出角色目录或不是普通文件: {relative}"));
    }
    Ok(canonical)
}

fn resolve_character_directory(root: &Path, id: &str) -> Result<PathBuf, String> {
    if !is_character_id(id) || id == "_placeholder" {
        return Err("本地角色 ID 无效".into());
    }
    let canonical_root =
        fs::canonicalize(root).map_err(|_| "本地角色根目录无法解析".to_string())?;
    let candidate = root.join(id);
    let metadata =
        fs::symlink_metadata(&candidate).map_err(|_| "本地角色目录不存在".to_string())?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err("本地角色目录不是普通目录".into());
    }
    let canonical = fs::canonicalize(&candidate).map_err(|_| "本地角色目录无法解析".to_string())?;
    if canonical != canonical_root.join(id) {
        return Err("本地角色目录包含重解析点或越出安全根目录".into());
    }
    Ok(canonical)
}

fn validate_display_assets(root: &Path, manifest: &CharacterManifest) -> Result<(), String> {
    if let Some(preview) = &manifest.preview {
        let path = resolve_existing_file(root, preview)?;
        let info = inspect_png(&path, 8 * 1024 * 1024)?;
        if info.width < 64 || info.height < 64 || info.width > 2_048 || info.height > 2_048 {
            return Err("preview 尺寸必须为 64-2048".into());
        }
    }
    if let Some(icon) = &manifest.icon {
        let path = resolve_existing_file(root, icon)?;
        let info = inspect_png(&path, 2 * 1024 * 1024)?;
        if info.width < 32
            || info.height < 32
            || info.width > 512
            || info.height > 512
            || info.width != info.height
        {
            return Err("icon 必须为 32-512 的正方形 PNG".into());
        }
    }
    Ok(())
}

fn validate_frames(
    root: &Path,
    manifest: &CharacterManifest,
    frames: &HashMap<String, Vec<String>>,
    decode_frames: bool,
) -> Result<(), String> {
    for state in frames.keys() {
        if !manifest.animations.contains_key(state) {
            return Err(format!("frames.json 包含未声明动作 {state}"));
        }
    }
    let mut decoded_pixels = 0_u64;
    for (state, animation) in &manifest.animations {
        let list = frames
            .get(state)
            .ok_or_else(|| format!("{state}: frames.json 缺少动作"))?;
        if list.is_empty() || list.len() > MAX_FRAMES_PER_ANIMATION {
            return Err(format!("{state}: 帧数必须为 1-{MAX_FRAMES_PER_ANIMATION}"));
        }
        let animation_path = animation.path.trim_end_matches('/');
        let mut seen = HashSet::new();
        for (index, relative) in list.iter().enumerate() {
            safe_relative_path(relative).map_err(|error| format!("{state}: {error}"))?;
            let expected_name = format!("{state}_{:04}.png", index + 1);
            let expected_prefix = format!("{animation_path}/");
            if !relative.starts_with(&expected_prefix)
                || Path::new(relative)
                    .file_name()
                    .and_then(|name| name.to_str())
                    != Some(&expected_name)
                || !relative.to_lowercase().ends_with(".png")
            {
                return Err(format!("{state}: 帧路径或编号无效: {relative}"));
            }
            if !seen.insert(relative.to_lowercase()) {
                return Err(format!("{state}: 帧路径重复"));
            }
            let path = resolve_existing_file(root, relative)?;
            let metadata = fs::metadata(&path).map_err(|_| "帧无法读取".to_string())?;
            if metadata.len() > MAX_ENTRY_BYTES {
                return Err(format!("{state}: 单帧超过 16 MiB"));
            }
            if decode_frames {
                let info = inspect_png(&path, MAX_ENTRY_BYTES)?;
                if info.width != manifest.frame_size.width
                    || info.height != manifest.frame_size.height
                    || info.color_type != png::ColorType::Rgba
                    || !matches!(
                        info.bit_depth,
                        png::BitDepth::Eight | png::BitDepth::Sixteen
                    )
                    || !info.has_transparency
                {
                    return Err(format!(
                        "{state}: PNG 必须匹配 frameSize、使用 RGBA 并包含透明像素"
                    ));
                }
                decoded_pixels = decoded_pixels
                    .checked_add(u64::from(info.width) * u64::from(info.height))
                    .ok_or_else(|| "角色总像素数溢出".to_string())?;
                if decoded_pixels > MAX_DECODED_FRAME_PIXELS {
                    return Err("角色帧总解码像素超过本地导入安全上限".into());
                }
            }
        }
    }
    Ok(())
}

fn validate_package(root: &Path, decode_frames: bool) -> Result<ValidatedPackage, String> {
    let manifest_value = read_json_value(&root.join("manifest.json"))?;
    let manifest: CharacterManifest = serde_json::from_value(manifest_value.clone())
        .map_err(|error| format!("manifest 字段无效: {error}"))?;
    validate_manifest(&manifest)?;
    let frame_value = read_json_value(&root.join("frames.json"))?;
    let frame_index: FrameIndex = serde_json::from_value(frame_value)
        .map_err(|error| format!("frames.json 字段无效: {error}"))?;
    validate_display_assets(root, &manifest)?;
    validate_frames(root, &manifest, &frame_index.animations, decode_frames)?;
    Ok(ValidatedPackage {
        manifest_value,
        manifest,
        frames: frame_index.animations,
    })
}

fn extract_archive(package_path: &Path, staging: &Path) -> Result<(), String> {
    let metadata = fs::metadata(package_path).map_err(|_| "角色包无法读取".to_string())?;
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > MAX_ARCHIVE_BYTES {
        return Err("角色包为空、不是普通文件或超过 512 MiB".into());
    }
    if package_path
        .extension()
        .and_then(|extension| extension.to_str())
        .is_none_or(|extension| !extension.eq_ignore_ascii_case("qipet"))
    {
        return Err("请选择 .qipet 角色包".into());
    }
    let file = File::open(package_path).map_err(|_| "角色包无法打开".to_string())?;
    let mut archive = ZipArchive::new(BufReader::new(file))
        .map_err(|error| format!("角色包不是有效 ZIP: {error}"))?;
    if archive.len() == 0 || archive.len() > MAX_ENTRIES + 256 {
        return Err("角色包条目数量无效或过多".into());
    }
    fs::create_dir_all(staging).map_err(|error| format!("无法创建导入暂存区: {error}"))?;
    let mut names = HashSet::new();
    let mut regular_files = 0_usize;
    let mut extracted_bytes = 0_u64;
    for index in 0..archive.len() {
        let mut entry = archive
            .by_index(index)
            .map_err(|error| format!("无法读取 ZIP 条目: {error}"))?;
        if entry.encrypted() {
            return Err("不支持加密角色包".into());
        }
        let raw_name = entry.name().trim_end_matches('/');
        let relative =
            safe_relative_path(raw_name).map_err(|error| format!("ZIP 条目路径无效: {error}"))?;
        let normalized = raw_name.to_lowercase();
        if !names.insert(normalized) {
            return Err("ZIP 包含大小写冲突或重复路径".into());
        }
        if let Some(mode) = entry.unix_mode() {
            let file_type = mode & 0o170000;
            if file_type != 0 && file_type != 0o100000 && !(entry.is_dir() && file_type == 0o040000)
            {
                return Err("ZIP 包含符号链接或非常规文件".into());
            }
        }
        if entry.is_dir() {
            fs::create_dir_all(staging.join(relative))
                .map_err(|error| format!("无法创建包内目录: {error}"))?;
            continue;
        }
        regular_files += 1;
        if regular_files > MAX_ENTRIES || entry.size() > MAX_ENTRY_BYTES {
            return Err("角色包文件数量或单文件大小超过上限".into());
        }
        let destination = staging.join(relative);
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent).map_err(|error| format!("无法创建包内目录: {error}"))?;
        }
        let mut bytes = Vec::with_capacity(entry.size().min(MAX_ENTRY_BYTES) as usize);
        entry
            .by_ref()
            .take(MAX_ENTRY_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|error| format!("无法解压角色包: {error}"))?;
        if bytes.len() as u64 > MAX_ENTRY_BYTES {
            return Err("解压后的单文件超过 16 MiB".into());
        }
        extracted_bytes = extracted_bytes
            .checked_add(bytes.len() as u64)
            .ok_or_else(|| "角色包解压大小溢出".to_string())?;
        if extracted_bytes > MAX_EXTRACTED_BYTES {
            return Err("角色包解压后超过 512 MiB".into());
        }
        let mut output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&destination)
            .map_err(|error| format!("无法写入暂存文件: {error}"))?;
        output
            .write_all(&bytes)
            .and_then(|_| output.sync_all())
            .map_err(|error| format!("无法完整写入暂存文件: {error}"))?;
    }
    if regular_files == 0 {
        return Err("角色包不包含文件".into());
    }
    Ok(())
}

fn display_asset_path(root: &Path, relative: Option<&String>) -> Option<String> {
    relative
        .and_then(|value| resolve_existing_file(root, value).ok())
        .map(|path| path.to_string_lossy().into_owned())
}

fn summary_from_validated(root: &Path, package: &ValidatedPackage) -> CharacterSummary {
    CharacterSummary {
        id: package.manifest.id.clone(),
        name: package.manifest.name.clone(),
        version: package.manifest.version.clone(),
        author: package.manifest.author.clone(),
        license: package.manifest.license.clone(),
        source: "local",
        valid: true,
        errors: Vec::new(),
        preview_path: display_asset_path(root, package.manifest.preview.as_ref()),
        icon_path: display_asset_path(root, package.manifest.icon.as_ref()),
    }
}

fn invalid_summary(id: String, error: String) -> CharacterSummary {
    CharacterSummary {
        name: id.clone(),
        id,
        version: "未知".into(),
        author: "未知".into(),
        license: "未知".into(),
        source: "local",
        valid: false,
        errors: vec![error],
        preview_path: None,
        icon_path: None,
    }
}

fn bundled_character_ids() -> Result<Vec<String>, String> {
    let index: Value = serde_json::from_str(BUNDLED_CHARACTER_INDEX_JSON)
        .map_err(|error| format!("内置角色索引无法读取: {error}"))?;
    let characters = index
        .get("characters")
        .and_then(Value::as_array)
        .ok_or_else(|| "内置角色索引缺少 characters 数组".to_string())?;
    characters
        .iter()
        .map(|entry| {
            entry
                .get("id")
                .and_then(Value::as_str)
                .filter(|id| is_character_id(id))
                .map(str::to_owned)
                .ok_or_else(|| "内置角色索引包含无效 ID".to_string())
        })
        .collect()
}

fn ensure_higher_version(current: &str, incoming: &str) -> Result<(), String> {
    let current = semver::Version::parse(current)
        .map_err(|_| "已安装角色版本不是 SemVer，不能自动更新；请先切换并删除旧包".to_string())?;
    let incoming = semver::Version::parse(incoming)
        .map_err(|_| "新角色版本不是 SemVer，不能覆盖已有角色".to_string())?;
    if incoming <= current {
        return Err(format!(
            "仅允许升级角色版本（已安装 {current}，导入 {incoming}）"
        ));
    }
    Ok(())
}

fn remove_internal_directory(path: &Path, allowed_parent: &Path) -> Result<(), String> {
    if !path.exists() {
        return Ok(());
    }
    let canonical_parent = fs::canonicalize(allowed_parent)
        .map_err(|error| format!("无法验证内部目录边界: {error}"))?;
    let canonical_path =
        fs::canonicalize(path).map_err(|error| format!("无法验证待清理目录: {error}"))?;
    if canonical_path == canonical_parent || !canonical_path.starts_with(&canonical_parent) {
        return Err("拒绝清理角色目录边界外的路径".into());
    }
    fs::remove_dir_all(canonical_path).map_err(|error| format!("无法清理内部目录: {error}"))
}

fn is_generated_internal_name(value: &str, prefix: &str) -> bool {
    value.starts_with(prefix)
        && value.len() > prefix.len()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'))
}

fn deletion_tombstone_name(id: &str) -> String {
    format!(".deleting-{}-{id}", now_token())
}

fn is_deletion_tombstone_name(value: &str) -> bool {
    let Some(rest) = value.strip_prefix(".deleting-") else {
        return false;
    };
    let mut parts = rest.splitn(3, '-');
    let Some(process_id) = parts.next() else {
        return false;
    };
    let Some(timestamp) = parts.next() else {
        return false;
    };
    let Some(id) = parts.next() else {
        return false;
    };
    !process_id.is_empty()
        && process_id.bytes().all(|byte| byte.is_ascii_digit())
        && !timestamp.is_empty()
        && timestamp.bytes().all(|byte| byte.is_ascii_digit())
        && is_character_id(id)
        && id != "_placeholder"
}

fn resolve_direct_internal_directory(parent: &Path, name: &str) -> Result<PathBuf, String> {
    let candidate = parent.join(name);
    let metadata = fs::symlink_metadata(&candidate).map_err(|_| "事务目录不存在".to_string())?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err("事务目录不是普通目录".into());
    }
    let canonical_parent =
        fs::canonicalize(parent).map_err(|_| "事务父目录无法解析".to_string())?;
    let canonical = fs::canonicalize(&candidate).map_err(|_| "事务目录无法解析".to_string())?;
    if canonical != canonical_parent.join(name) {
        return Err("事务目录包含重解析点或越出安全目录".into());
    }
    Ok(canonical)
}

fn move_character_to_deletion_tombstone(root: &Path, id: &str) -> Result<Option<PathBuf>, String> {
    let destination = root.join(id);
    if !destination.exists() {
        return Ok(None);
    }
    let checked = resolve_character_directory(root, id)?;
    let tombstone = root.join(deletion_tombstone_name(id));
    fs::rename(&checked, &tombstone)
        .map_err(|error| format!("无法将角色原子移出可见目录: {error}"))?;
    Ok(Some(tombstone))
}

fn cleanup_deletion_tombstone(root: &Path, tombstone: &Path) -> Result<(), String> {
    let name = tombstone
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| "删除 tombstone 名称无效".to_string())?;
    if !is_deletion_tombstone_name(name) {
        return Err("拒绝清理名称不受信任的删除 tombstone".into());
    }
    let checked = resolve_direct_internal_directory(root, name)?;
    remove_internal_directory(&checked, root)
}

fn validate_transaction_package(path: &Path, id: &str) -> Result<(), String> {
    let package = validate_package(path, true)?;
    if package.manifest.id != id {
        return Err("事务角色 ID 与 manifest 不一致".into());
    }
    Ok(())
}

fn write_install_transaction(
    root: &Path,
    token: &str,
    transaction: &InstallTransaction,
) -> Result<PathBuf, String> {
    let path = root.join(format!("{TRANSACTION_PREFIX}{token}.json"));
    let temporary = root.join(format!("{TRANSACTION_PREFIX}{token}.json.tmp"));
    let bytes = serde_json::to_vec_pretty(transaction)
        .map_err(|error| format!("无法序列化角色安装事务: {error}"))?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .map_err(|error| format!("无法创建角色安装事务: {error}"))?;
    if let Err(error) = file.write_all(&bytes).and_then(|_| file.sync_all()) {
        drop(file);
        let _ = fs::remove_file(&temporary);
        return Err(format!("无法持久化角色安装事务: {error}"));
    }
    drop(file);
    if let Err(error) = fs::rename(&temporary, &path) {
        let _ = fs::remove_file(&temporary);
        return Err(format!("无法提交角色安装事务: {error}"));
    }
    Ok(path)
}

fn complete_install_transaction(path: &Path) -> Result<(), String> {
    fs::remove_file(path).map_err(|error| format!("无法清理角色安装事务: {error}"))
}

fn recover_install_transaction(root: &Path, journal_path: &Path) -> Result<(), String> {
    let metadata =
        fs::symlink_metadata(journal_path).map_err(|_| "角色安装事务日志不存在".to_string())?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err("角色安装事务日志不是普通文件".into());
    }
    let value = read_json_value(journal_path)?;
    let transaction: InstallTransaction =
        serde_json::from_value(value).map_err(|error| format!("角色安装事务日志无效: {error}"))?;
    if !is_character_id(&transaction.id)
        || transaction.id == "_placeholder"
        || !is_generated_internal_name(&transaction.staging_name, "import-")
        || transaction.backup_name.as_deref().is_some_and(|name| {
            !is_generated_internal_name(name, &format!(".backup-{}-", transaction.id))
        })
    {
        return Err("角色安装事务包含不安全的目录名称".into());
    }

    let destination = root.join(&transaction.id);
    let staging_parent = root.join(".staging");
    let staging = staging_parent.join(&transaction.staging_name);
    let backup = transaction.backup_name.as_ref().map(|name| root.join(name));

    if destination.exists() {
        let destination_validation =
            resolve_character_directory(root, &transaction.id).and_then(|checked| {
                validate_transaction_package(&checked, &transaction.id).map(|_| checked)
            });
        if let Err(destination_error) = destination_validation {
            let (backup_name, _backup_path) = transaction
                .backup_name
                .as_deref()
                .zip(backup.as_ref())
                .filter(|(_, path)| path.exists())
                .ok_or_else(|| {
                    format!(
                        "已提交角色无法通过完整恢复校验，且没有可用旧版备份: {destination_error}"
                    )
                })?;
            let checked_backup = resolve_direct_internal_directory(root, backup_name)?;
            validate_transaction_package(&checked_backup, &transaction.id).map_err(|error| {
                format!(
                    "已提交角色无效（{destination_error}），旧版备份也无法通过完整恢复校验: {error}"
                )
            })?;
            let checked_destination =
                resolve_character_directory(root, &transaction.id).map_err(|error| {
                    format!("已提交角色无效，但无法安全隔离坏目录；旧版备份已保留: {error}")
                })?;
            let tombstone = root.join(deletion_tombstone_name(&transaction.id));
            fs::rename(&checked_destination, &tombstone)
                .map_err(|error| format!("无法安全隔离无效的新角色目录: {error}"))?;
            if let Err(restore_error) = fs::rename(&checked_backup, &destination) {
                let rollback = fs::rename(&tombstone, &destination);
                return Err(match rollback {
                    Ok(()) => format!(
                        "无法从有效旧版备份恢复角色: {restore_error}；无效新目录已恢复原位，备份仍保留"
                    ),
                    Err(rollback_error) => format!(
                        "无法从有效旧版备份恢复角色: {restore_error}；无效目录隔离后也无法回滚: {rollback_error}。事务日志、备份和 tombstone 均已保留"
                    ),
                });
            }
            log::warn!(
                "invalid committed local character was quarantined and the valid previous package was restored"
            );
        }
    } else if let Some((backup_name, backup_path)) = transaction
        .backup_name
        .as_deref()
        .zip(backup.as_ref())
        .filter(|(_, path)| path.exists())
    {
        let checked = resolve_direct_internal_directory(root, backup_name)?;
        validate_transaction_package(&checked, &transaction.id)
            .map_err(|error| format!("旧角色备份无法通过恢复校验: {error}"))?;
        fs::rename(backup_path, &destination)
            .map_err(|error| format!("无法从事务备份恢复旧角色: {error}"))?;
    } else if staging.exists() {
        let checked =
            resolve_direct_internal_directory(&staging_parent, &transaction.staging_name)?;
        validate_transaction_package(&checked, &transaction.id)
            .map_err(|error| format!("暂存角色无法通过恢复校验: {error}"))?;
        fs::rename(&staging, &destination)
            .map_err(|error| format!("无法完成中断的首次角色安装: {error}"))?;
    } else {
        return Err("角色安装事务无法恢复：目标、备份和暂存目录均不可用".into());
    }

    if let Some((backup_name, backup_path)) = transaction.backup_name.as_deref().zip(backup) {
        if backup_path.exists() {
            let checked = resolve_direct_internal_directory(root, backup_name)?;
            remove_internal_directory(&checked, root)?;
        }
    }
    if staging.exists() {
        let checked =
            resolve_direct_internal_directory(&staging_parent, &transaction.staging_name)?;
        remove_internal_directory(&checked, &staging_parent)?;
    }
    complete_install_transaction(journal_path)
}

fn recover_install_transactions(root: &Path) -> Result<(), String> {
    let mut journals = Vec::new();
    for entry in fs::read_dir(root).map_err(|error| format!("无法扫描角色安装事务: {error}"))?
    {
        let entry = entry.map_err(|error| format!("无法读取角色安装事务条目: {error}"))?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with(TRANSACTION_PREFIX) && name.ends_with(".json") {
            journals.push(entry.path());
        }
    }
    journals.sort();
    for journal in journals {
        recover_install_transaction(root, &journal)?;
        log::warn!("recovered an interrupted local character installation transaction");
    }
    Ok(())
}

fn cleanup_orphan_transaction_temps(root: &Path) -> Result<(), String> {
    for entry in fs::read_dir(root).map_err(|error| format!("无法扫描事务临时文件: {error}"))?
    {
        let entry = entry.map_err(|error| format!("无法读取事务临时条目: {error}"))?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.starts_with(TRANSACTION_PREFIX) || !name.ends_with(".json.tmp") {
            continue;
        }
        let file_type = entry
            .file_type()
            .map_err(|error| format!("无法检查事务临时文件: {error}"))?;
        if !file_type.is_file() || file_type.is_symlink() {
            return Err("事务临时路径不是普通文件".into());
        }
        fs::remove_file(entry.path()).map_err(|error| format!("无法清理事务临时文件: {error}"))?;
    }
    Ok(())
}

fn cleanup_orphan_staging(staging_parent: &Path) -> Result<(), String> {
    for entry in
        fs::read_dir(staging_parent).map_err(|error| format!("无法扫描导入暂存目录: {error}"))?
    {
        let entry = entry.map_err(|error| format!("无法读取导入暂存条目: {error}"))?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !is_generated_internal_name(&name, "import-") {
            continue;
        }
        let checked = resolve_direct_internal_directory(staging_parent, &name)?;
        remove_internal_directory(&checked, staging_parent)?;
    }
    Ok(())
}

fn cleanup_orphan_deletion_tombstones(root: &Path) -> Result<(), String> {
    for entry in
        fs::read_dir(root).map_err(|error| format!("无法扫描角色删除 tombstone: {error}"))?
    {
        let entry = entry.map_err(|error| format!("无法读取角色删除 tombstone 条目: {error}"))?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !is_deletion_tombstone_name(&name) {
            continue;
        }
        if let Err(error) = cleanup_deletion_tombstone(root, &entry.path()) {
            log::warn!(
                "retained local character deletion tombstone for a later cleanup attempt: {error}"
            );
        }
    }
    Ok(())
}

fn prepare_character_root(root: &Path) -> Result<PathBuf, String> {
    fs::create_dir_all(root).map_err(|error| format!("无法创建本地角色目录: {error}"))?;
    let staging_parent = root.join(".staging");
    fs::create_dir_all(&staging_parent).map_err(|error| format!("无法创建暂存根目录: {error}"))?;
    recover_install_transactions(root)?;
    cleanup_orphan_transaction_temps(root)?;
    cleanup_orphan_staging(&staging_parent)?;
    cleanup_orphan_deletion_tombstones(root)?;
    Ok(staging_parent)
}

fn install_package_at(
    root: &Path,
    package_path: &Path,
    built_in_ids: &[String],
) -> Result<CharacterSummary, String> {
    let staging_parent = prepare_character_root(root)?;
    let token = now_token();
    let staging_name = format!("import-{token}");
    let staging = staging_parent.join(&staging_name);
    let result = (|| {
        extract_archive(package_path, &staging)?;
        let validated = validate_package(&staging, true)?;
        if validated.manifest.id == "_placeholder"
            || built_in_ids
                .iter()
                .any(|id| id.eq_ignore_ascii_case(&validated.manifest.id))
        {
            return Err("本地角色包不能覆盖内置角色 ID".into());
        }
        let destination = root.join(&validated.manifest.id);
        if destination.exists() {
            let checked_destination = resolve_character_directory(root, &validated.manifest.id)?;
            let current = validate_package(&checked_destination, false).map_err(|_| {
                "同 ID 的已安装角色已损坏；请先切换到其他角色并删除旧包".to_string()
            })?;
            ensure_higher_version(&current.manifest.version, &validated.manifest.version)?;
        }
        let backup_name = format!(".backup-{}-{token}", validated.manifest.id);
        let backup = root.join(&backup_name);
        let had_previous = destination.exists();
        let transaction = InstallTransaction {
            id: validated.manifest.id.clone(),
            staging_name: staging_name.clone(),
            backup_name: had_previous.then_some(backup_name),
        };
        let journal = write_install_transaction(root, &token, &transaction)?;
        if had_previous {
            fs::rename(&destination, &backup)
                .map_err(|error| format!("无法暂存旧角色版本: {error}"))?;
        }
        if let Err(error) = fs::rename(&staging, &destination) {
            if had_previous {
                if let Err(restore_error) = fs::rename(&backup, &destination) {
                    return Err(format!(
                        "无法提交角色安装: {error}；旧版本自动恢复也失败: {restore_error}。旧版本仍保留在内部备份目录中"
                    ));
                }
            }
            if let Err(cleanup_error) = complete_install_transaction(&journal) {
                return Err(format!(
                    "无法提交角色安装: {error}；旧版本已恢复，但 {cleanup_error}"
                ));
            }
            return Err(format!("无法提交角色安装: {error}"));
        }
        let mut cleanup_complete = true;
        if had_previous {
            if let Err(error) = remove_internal_directory(&backup, root) {
                log::warn!("cannot remove previous local character backup: {error}");
                cleanup_complete = false;
            }
        }
        if cleanup_complete {
            if let Err(error) = complete_install_transaction(&journal) {
                log::warn!("cannot remove completed local character transaction: {error}");
            }
        } else {
            log::warn!("retained local character transaction journal for cleanup recovery");
        }
        Ok(summary_from_validated(&destination, &validated))
    })();
    if staging.exists() {
        let _ = remove_internal_directory(&staging, &staging_parent);
    }
    result
}

#[tauri::command]
pub fn list_installed_characters<R: Runtime>(
    app: AppHandle<R>,
    state: tauri::State<'_, CharacterCatalogLock>,
) -> Result<Vec<CharacterSummary>, String> {
    let _guard = state.0.lock().map_err(|_| "角色目录锁已损坏".to_string())?;
    let root = character_root(&app)?;
    prepare_character_root(&root)?;
    let mut directories = fs::read_dir(&root)
        .map_err(|error| format!("无法读取本地角色目录: {error}"))?
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .filter(|entry| !entry.file_name().to_string_lossy().starts_with('.'))
        .collect::<Vec<_>>();
    directories.sort_by_key(|entry| entry.file_name().to_string_lossy().to_lowercase());
    Ok(directories
        .into_iter()
        .map(|entry| {
            let id = entry.file_name().to_string_lossy().into_owned();
            let directory = resolve_character_directory(&root, &id);
            match directory
                .and_then(|path| validate_package(&path, false).map(|package| (path, package)))
            {
                Ok((path, package)) if package.manifest.id == id => {
                    summary_from_validated(&path, &package)
                }
                Ok(_) => invalid_summary(id, "目录 ID 与 manifest ID 不一致".into()),
                Err(error) => invalid_summary(id, error),
            }
        })
        .collect())
}

#[tauri::command]
pub fn load_installed_character<R: Runtime>(
    app: AppHandle<R>,
    id: String,
    state: tauri::State<'_, CharacterCatalogLock>,
) -> Result<LoadedCharacterPackage, String> {
    let _guard = state.0.lock().map_err(|_| "角色目录锁已损坏".to_string())?;
    if !is_character_id(&id) || id == "_placeholder" {
        return Err("本地角色 ID 无效".into());
    }
    let root = character_root(&app)?;
    prepare_character_root(&root)?;
    let directory = resolve_character_directory(&root, &id)?;
    let package = validate_package(&directory, false)?;
    if package.manifest.id != id {
        return Err("目录 ID 与 manifest ID 不一致".into());
    }
    let mut absolute_frames = HashMap::new();
    for (state, frames) in &package.frames {
        let paths = frames
            .iter()
            .map(|relative| {
                resolve_existing_file(&directory, relative)
                    .map(|path| path.to_string_lossy().into_owned())
            })
            .collect::<Result<Vec<_>, _>>()?;
        absolute_frames.insert(state.clone(), paths);
    }
    Ok(LoadedCharacterPackage {
        manifest: package.manifest_value,
        frames: absolute_frames,
        preview_path: display_asset_path(&directory, package.manifest.preview.as_ref()),
        icon_path: display_asset_path(&directory, package.manifest.icon.as_ref()),
    })
}

#[tauri::command]
pub async fn import_character_package<R: Runtime>(
    app: AppHandle<R>,
    state: tauri::State<'_, CharacterCatalogLock>,
) -> Result<Option<CharacterSummary>, String> {
    let built_in_ids = bundled_character_ids()?;
    let picker_app = app.clone();
    let selected = tauri::async_runtime::spawn_blocking(move || {
        picker_app
            .dialog()
            .file()
            .add_filter("七酱桌宠角色包", &["qipet"])
            .blocking_pick_file()
    })
    .await
    .map_err(|error| format!("角色包选择器失败: {error}"))?;
    let Some(selected) = selected else {
        return Ok(None);
    };
    let package_path = selected
        .into_path()
        .map_err(|_| "选择结果不是本地文件路径".to_string())?;
    let root = character_root(&app)?;
    let catalog_lock = state.0.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _guard = catalog_lock
            .lock()
            .map_err(|_| "角色目录锁已损坏".to_string())?;
        install_package_at(&root, &package_path, &built_in_ids)
    })
    .await
    .map_err(|error| format!("角色包导入任务失败: {error}"))?
    .map(Some)
}

fn persisted_character_id<R: Runtime>(app: &AppHandle<R>) -> Result<Option<String>, String> {
    let settings_path = app
        .path()
        .app_config_dir()
        .map_err(|error| format!("无法解析设置目录: {error}"))?
        .join("settings.json");
    if !settings_path.exists() {
        return Ok(None);
    }
    let value = read_json_value(&settings_path)
        .map_err(|error| format!("无法确认当前角色，拒绝删除: {error}"))?;
    Ok(value
        .get("settings")
        .and_then(|settings| settings.get("characterId"))
        .and_then(Value::as_str)
        .map(str::to_owned))
}

fn ensure_active_character_initialized<R: Runtime>(
    app: &AppHandle<R>,
    state: &ActiveCharacterState,
) -> Result<(), String> {
    if state
        .0
        .lock()
        .map_err(|_| "原生角色选择状态锁已损坏".to_string())?
        .initialized
    {
        return Ok(());
    }
    let persisted = persisted_character_id(app)?;
    let mut selection = state
        .0
        .lock()
        .map_err(|_| "原生角色选择状态锁已损坏".to_string())?;
    if !selection.initialized {
        selection.active_id = persisted;
        selection.initialized = true;
    }
    Ok(())
}

fn cleanup_expired_pending_selections(selection: &mut NativeCharacterSelection, now_ms: u64) {
    reconcile_expired_pending_selections(selection, now_ms, None);
}

fn reconcile_expired_pending_selections(
    selection: &mut NativeCharacterSelection,
    now_ms: u64,
    persisted_id: Option<&str>,
) {
    let active_id = selection.active_id.clone();
    let activation_generation = selection.activation_generation;
    let mut promotion: Option<(String, u64)> = None;
    selection.pending.retain(|_, pending| {
        if pending.expires_at_ms > now_ms {
            return true;
        }
        let Some(generation) = pending.authorized_generation else {
            return false;
        };
        if activation_generation > generation
            || (activation_generation >= generation
                && active_id.as_deref() == Some(pending.id.as_str()))
        {
            return false;
        }
        if persisted_id == Some(pending.id.as_str()) {
            if promotion
                .as_ref()
                .is_none_or(|(_, current_generation)| generation > *current_generation)
            {
                promotion = Some((pending.id.clone(), generation));
            }
            return false;
        }
        true
    });
    if let Some((id, generation)) = promotion {
        selection.active_id = Some(id);
        selection.activation_generation = selection.activation_generation.max(generation);
        selection.initialized = true;
    }
}

fn selection_blocks_removal(selection: &NativeCharacterSelection, id: &str) -> bool {
    selection.active_id.as_deref() == Some(id)
        || selection.pending.values().any(|pending| pending.id == id)
}

fn accepts_activation_generation(selection: &NativeCharacterSelection, generation: u64) -> bool {
    generation >= selection.activation_generation
}

#[tauri::command]
pub fn get_selected_character_id<R: Runtime>(
    app: AppHandle<R>,
    state: tauri::State<'_, ActiveCharacterState>,
) -> Result<Option<String>, String> {
    ensure_active_character_initialized(&app, &state)?;
    let selection = state
        .0
        .lock()
        .map_err(|_| "原生角色选择状态锁已损坏".to_string())?;
    Ok(selection.active_id.clone())
}

#[tauri::command]
pub fn set_active_character_id<R: Runtime>(
    app: AppHandle<R>,
    id: String,
    generation: u64,
    state: tauri::State<'_, ActiveCharacterState>,
) -> Result<bool, String> {
    if !is_character_id(&id) {
        return Err("原生当前角色 ID 无效".into());
    }
    ensure_active_character_initialized(&app, &state)?;
    let mut selection = state
        .0
        .lock()
        .map_err(|_| "原生角色选择状态锁已损坏".to_string())?;
    if !accepts_activation_generation(&selection, generation) {
        return Ok(false);
    }
    selection.active_id = Some(id);
    selection.activation_generation = generation;
    selection.initialized = true;
    Ok(true)
}

#[tauri::command]
pub fn begin_character_activation<R: Runtime>(
    app: AppHandle<R>,
    id: String,
    request_id: String,
    generation: u64,
    state: tauri::State<'_, ActiveCharacterState>,
) -> Result<(), String> {
    if !is_character_id(&id) || !is_request_id(&request_id) {
        return Err("角色激活准备参数无效".into());
    }
    ensure_active_character_initialized(&app, &state)?;
    let now = unix_time_ms();
    let mut selection = state
        .0
        .lock()
        .map_err(|_| "原生角色选择状态锁已损坏".to_string())?;
    if !accepts_activation_generation(&selection, generation) {
        return Err("角色激活准备已被更新的激活代次取代".into());
    }
    cleanup_expired_pending_selections(&mut selection, now);
    if !selection.pending.contains_key(&request_id)
        && selection.pending.len() >= MAX_PENDING_SELECTIONS
    {
        return Err("待处理角色激活请求过多，请稍后重试".into());
    }
    selection.pending.insert(
        request_id,
        PendingCharacterSelection {
            id,
            expires_at_ms: now.saturating_add(MAX_SELECTION_REQUEST_LIFETIME_MS),
            authorized_generation: Some(generation),
        },
    );
    Ok(())
}

#[tauri::command]
pub fn commit_character_selection(
    id: String,
    request_id: String,
    generation: u64,
    state: tauri::State<'_, ActiveCharacterState>,
) -> Result<(), String> {
    if !is_character_id(&id) || !is_request_id(&request_id) {
        return Err("角色切换提交参数无效".into());
    }
    let mut selection = state
        .0
        .lock()
        .map_err(|_| "原生角色选择状态锁已损坏".to_string())?;
    if !accepts_activation_generation(&selection, generation) {
        return Err("角色切换授权已被更新的激活代次取代".into());
    }
    let pending = selection
        .pending
        .get_mut(&request_id)
        .ok_or_else(|| "角色切换请求已取消或不存在".to_string())?;
    if pending.id != id {
        return Err("角色切换提交与待处理角色不一致".into());
    }
    if pending.expires_at_ms <= unix_time_ms() {
        selection.pending.remove(&request_id);
        return Err("角色切换请求已过期".into());
    }
    pending.authorized_generation = Some(generation);
    Ok(())
}

#[tauri::command]
pub fn finalize_character_selection(
    id: String,
    request_id: String,
    generation: u64,
    state: tauri::State<'_, ActiveCharacterState>,
) -> Result<(), String> {
    if !is_character_id(&id) || !is_request_id(&request_id) {
        return Err("角色切换完成参数无效".into());
    }
    let mut selection = state
        .0
        .lock()
        .map_err(|_| "原生角色选择状态锁已损坏".to_string())?;
    let pending = selection
        .pending
        .get(&request_id)
        .ok_or_else(|| "角色切换请求已取消或不存在".to_string())?;
    if pending.id != id || pending.authorized_generation != Some(generation) {
        return Err("角色切换完成与已授权请求不一致".into());
    }
    if !accepts_activation_generation(&selection, generation) {
        return Err("角色切换完成已被更新的激活代次取代".into());
    }
    selection.active_id = Some(id);
    selection.activation_generation = generation;
    selection.initialized = true;
    selection.pending.remove(&request_id);
    Ok(())
}

#[tauri::command]
pub fn cancel_character_selection(
    request_id: String,
    state: tauri::State<'_, ActiveCharacterState>,
) -> Result<bool, String> {
    if !is_request_id(&request_id) {
        return Err("角色切换取消参数无效".into());
    }
    let mut selection = state
        .0
        .lock()
        .map_err(|_| "原生角色选择状态锁已损坏".to_string())?;
    Ok(selection.pending.remove(&request_id).is_some())
}

#[tauri::command]
pub fn request_character_selection<R: Runtime>(
    app: AppHandle<R>,
    id: String,
    source: String,
    request_id: String,
    expires_at_ms: u64,
    state: tauri::State<'_, ActiveCharacterState>,
) -> Result<(), String> {
    let now = unix_time_ms();
    if !is_character_id(&id)
        || !matches!(source.as_str(), "bundled" | "local")
        || !is_request_id(&request_id)
        || !is_selection_deadline_valid(expires_at_ms, now)
    {
        return Err("角色切换请求无效".into());
    }
    ensure_active_character_initialized(&app, &state)?;
    {
        let mut selection = state
            .0
            .lock()
            .map_err(|_| "原生角色选择状态锁已损坏".to_string())?;
        cleanup_expired_pending_selections(&mut selection, now);
        if !selection.pending.contains_key(&request_id)
            && selection.pending.len() >= MAX_PENDING_SELECTIONS
        {
            return Err("待处理角色切换请求过多，请稍后重试".into());
        }
        selection.pending.insert(
            request_id.clone(),
            PendingCharacterSelection {
                id: id.clone(),
                expires_at_ms,
                authorized_generation: None,
            },
        );
    }
    if let Err(error) = app.emit_to(
        "main",
        "character-selection-requested",
        CharacterSelectionRequest {
            id,
            source,
            request_id: request_id.clone(),
            expires_at_ms,
        },
    ) {
        if let Ok(mut selection) = state.0.lock() {
            selection.pending.remove(&request_id);
        }
        return Err(format!("无法发送角色切换请求: {error}"));
    }
    Ok(())
}

#[tauri::command]
pub fn remove_installed_character<R: Runtime>(
    app: AppHandle<R>,
    id: String,
    catalog_state: tauri::State<'_, CharacterCatalogLock>,
    active_state: tauri::State<'_, ActiveCharacterState>,
) -> Result<bool, String> {
    if !is_character_id(&id) || id == "_placeholder" {
        return Err("本地角色 ID 无效".into());
    }
    ensure_active_character_initialized(&app, &active_state)?;
    let persisted = persisted_character_id(&app).ok().flatten();
    let mut selection = active_state
        .0
        .lock()
        .map_err(|_| "原生角色选择状态锁已损坏".to_string())?;
    reconcile_expired_pending_selections(&mut selection, unix_time_ms(), persisted.as_deref());
    if selection_blocks_removal(&selection, &id) {
        return Err("当前正在使用或正在切换到的本地角色不能删除，请先切换外观".into());
    }
    let _guard = catalog_state
        .0
        .lock()
        .map_err(|_| "角色目录锁已损坏".to_string())?;
    let root = character_root(&app)?;
    prepare_character_root(&root)?;
    let tombstone = move_character_to_deletion_tombstone(&root, &id)?;
    drop(selection);
    let Some(tombstone) = tombstone else {
        return Ok(false);
    };
    if let Err(error) = cleanup_deletion_tombstone(&root, &tombstone) {
        log::warn!(
            "local character was removed from the visible catalog but its deletion tombstone was retained: {error}"
        );
    }
    Ok(true)
}

pub fn show_appearance_window_for<R: Runtime>(app: &AppHandle<R>) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("appearance") {
        window
            .show()
            .map_err(|error| format!("无法显示外观中心: {error}"))?;
        window
            .set_focus()
            .map_err(|error| format!("无法聚焦外观中心: {error}"))?;
        return Ok(());
    }
    WebviewWindowBuilder::new(app, "appearance", WebviewUrl::App("index.html".into()))
        .title("七酱桌宠 · 外观中心")
        .inner_size(960.0, 720.0)
        .min_inner_size(560.0, 360.0)
        .resizable(true)
        .decorations(true)
        .transparent(false)
        .always_on_top(false)
        .skip_taskbar(false)
        .center()
        .build()
        .map(|_| ())
        .map_err(|error| format!("无法创建外观中心: {error}"))
}

// Dispatch WebView2 construction away from the IPC event thread. Keeping this
// command synchronous on Windows can deadlock navigation at about:blank.
#[tauri::command(async)]
pub fn show_appearance_window<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    crate::run_on_main_thread_with_result(&app, |app| show_appearance_window_for(&app))
}

#[cfg(test)]
mod tests {
    use super::{
        accepts_activation_generation, bundled_character_ids, cleanup_expired_pending_selections,
        ensure_higher_version, install_package_at, is_animation_state, is_character_id,
        is_deletion_tombstone_name, is_request_id, is_reserved_windows_component,
        is_selection_deadline_valid, move_character_to_deletion_tombstone, prepare_character_root,
        reconcile_expired_pending_selections, recover_install_transactions, safe_relative_path,
        selection_blocks_removal, validate_transaction_package, write_install_transaction,
        InstallTransaction, NativeCharacterSelection, PendingCharacterSelection,
    };
    use std::{
        fs::{self, File},
        io::Write,
        path::{Path, PathBuf},
        time::{SystemTime, UNIX_EPOCH},
    };
    use zip::{write::SimpleFileOptions, CompressionMethod, ZipWriter};

    fn temporary_directory(label: &str) -> PathBuf {
        let token = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "desk-pet-character-{label}-{}-{token}",
            std::process::id()
        ))
    }

    fn rgba_png(width: u32, height: u32) -> Vec<u8> {
        let mut output = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut output, width, height);
            encoder.set_color(png::ColorType::Rgba);
            encoder.set_depth(png::BitDepth::Eight);
            let mut writer = encoder.write_header().unwrap();
            writer
                .write_image_data(&vec![0_u8; width as usize * height as usize * 4])
                .unwrap();
        }
        output
    }

    fn add_file(zip: &mut ZipWriter<File>, name: &str, bytes: &[u8], permissions: Option<u32>) {
        let mut options =
            SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
        if let Some(permissions) = permissions {
            options = options.unix_permissions(permissions);
        }
        zip.start_file(name, options).unwrap();
        zip.write_all(bytes).unwrap();
    }

    fn write_package(
        path: &Path,
        id: &str,
        version: &str,
        frame: Option<&[u8]>,
        extra: Option<(&str, &[u8], Option<u32>)>,
    ) {
        let manifest = serde_json::json!({
            "schemaVersion": 1,
            "id": id,
            "name": "Test Character",
            "version": version,
            "author": "Test",
            "license": "Private use",
            "defaultScale": 1,
            "frameSize": { "width": 16, "height": 16 },
            "anchor": { "x": 0.5, "y": 1 },
            "preview": "preview.png",
            "icon": "icon.png",
            "animations": {
                "idle": { "path": "animations/idle", "fps": 8, "loop": true }
            }
        });
        let frames = serde_json::json!({
            "animations": { "idle": ["animations/idle/idle_0001.png"] }
        });
        let file = File::create(path).unwrap();
        let mut zip = ZipWriter::new(file);
        add_file(
            &mut zip,
            "manifest.json",
            serde_json::to_string(&manifest).unwrap().as_bytes(),
            None,
        );
        add_file(
            &mut zip,
            "frames.json",
            serde_json::to_string(&frames).unwrap().as_bytes(),
            None,
        );
        add_file(&mut zip, "preview.png", &rgba_png(64, 64), None);
        add_file(&mut zip, "icon.png", &rgba_png(32, 32), None);
        let default_frame = rgba_png(16, 16);
        add_file(
            &mut zip,
            "animations/idle/idle_0001.png",
            frame.unwrap_or(&default_frame),
            None,
        );
        if let Some((name, bytes, permissions)) = extra {
            if permissions == Some(0o120777) {
                zip.add_symlink(
                    name,
                    String::from_utf8_lossy(bytes),
                    SimpleFileOptions::default(),
                )
                .unwrap();
            } else {
                add_file(&mut zip, name, bytes, permissions);
            }
        }
        zip.finish().unwrap();
    }

    #[test]
    fn identifiers_and_states_follow_schema_one_rules() {
        assert!(is_character_id("person_01-alt"));
        assert!(is_character_id("_placeholder"));
        assert!(!is_character_id("Person"));
        assert!(is_animation_state("walk_left"));
        assert!(!is_animation_state("_idle"));
        assert!(is_request_id("request-01_ab"));
        assert!(!is_request_id("request 01"));
        assert!(is_selection_deadline_valid(110_000, 1));
        assert!(!is_selection_deadline_valid(1, 1));
        assert!(!is_selection_deadline_valid(120_002, 1));
    }

    #[test]
    fn native_active_and_pending_selection_state_blocks_only_live_roles() {
        let mut selection = NativeCharacterSelection {
            initialized: true,
            active_id: Some("old_role".into()),
            ..NativeCharacterSelection::default()
        };
        selection.pending.insert(
            "request-live".into(),
            PendingCharacterSelection {
                id: "new_role".into(),
                expires_at_ms: 20_000,
                authorized_generation: None,
            },
        );
        selection.pending.insert(
            "request-expired".into(),
            PendingCharacterSelection {
                id: "expired_role".into(),
                expires_at_ms: 9_999,
                authorized_generation: None,
            },
        );

        cleanup_expired_pending_selections(&mut selection, 10_000);
        assert!(selection_blocks_removal(&selection, "old_role"));
        assert!(selection_blocks_removal(&selection, "new_role"));
        assert!(!selection_blocks_removal(&selection, "expired_role"));

        selection.active_id = Some("new_role".into());
        selection.pending.remove("request-live");
        assert!(!selection_blocks_removal(&selection, "old_role"));
        assert!(selection_blocks_removal(&selection, "new_role"));

        selection.pending.insert(
            "request-authorized".into(),
            PendingCharacterSelection {
                id: "persisted_role".into(),
                expires_at_ms: 9_999,
                authorized_generation: Some(7),
            },
        );
        reconcile_expired_pending_selections(&mut selection, 10_000, Some("persisted_role"));
        assert_eq!(selection.active_id.as_deref(), Some("persisted_role"));
        assert_eq!(selection.activation_generation, 7);
        assert!(!selection.pending.contains_key("request-authorized"));
        assert!(!accepts_activation_generation(&selection, 6));
        assert!(accepts_activation_generation(&selection, 7));
        assert!(accepts_activation_generation(&selection, 8));
    }

    #[test]
    fn bundled_collision_source_is_compiled_into_the_native_binary() {
        let ids = bundled_character_ids().expect("bundled index must parse");
        assert!(ids.iter().any(|id| id == "_placeholder"));
    }

    #[test]
    fn archive_paths_reject_traversal_and_windows_aliases() {
        for invalid in [
            "../manifest.json",
            "/manifest.json",
            "animations\\idle.png",
            "animations//idle.png",
            "CON/file.png",
            "frames.json.",
            "C:/frame.png",
        ] {
            assert!(safe_relative_path(invalid).is_err(), "{invalid}");
        }
        assert!(safe_relative_path("animations/idle/idle_0001.png").is_ok());
        assert!(is_reserved_windows_component("LPT9.txt"));
    }

    #[test]
    fn updates_require_strictly_higher_semver_only_on_collision() {
        assert!(ensure_higher_version("1.0.0", "1.0.1").is_ok());
        assert!(ensure_higher_version("1.0.0", "1.0.0").is_err());
        assert!(ensure_higher_version("2.0.0", "1.9.9").is_err());
        assert!(ensure_higher_version("private", "2.0.0").is_err());
    }

    #[test]
    fn valid_packages_install_and_only_upgrade_forward() {
        let base = temporary_directory("upgrade");
        let root = base.join("characters");
        fs::create_dir_all(&base).unwrap();
        let first = base.join("first.qipet");
        let same = base.join("same.qipet");
        let upgrade = base.join("upgrade.qipet");
        write_package(&first, "my_character", "1.0.0", None, None);
        write_package(&same, "my_character", "1.0.0", None, None);
        write_package(&upgrade, "my_character", "1.1.0", None, None);

        let installed = install_package_at(&root, &first, &[]).unwrap();
        assert_eq!(installed.id, "my_character");
        assert_eq!(installed.version, "1.0.0");
        assert!(install_package_at(&root, &same, &[]).is_err());
        let upgraded = install_package_at(&root, &upgrade, &[]).unwrap();
        assert_eq!(upgraded.version, "1.1.0");
        let manifest: serde_json::Value =
            serde_json::from_slice(&fs::read(root.join("my_character/manifest.json")).unwrap())
                .unwrap();
        assert_eq!(manifest["version"], "1.1.0");
        assert!(!fs::read_dir(&root)
            .unwrap()
            .filter_map(Result::ok)
            .any(|entry| entry.file_name().to_string_lossy().starts_with(".backup-")));
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn deletion_moves_a_role_out_of_the_visible_catalog_before_cleanup() {
        let base = temporary_directory("delete-tombstone");
        let root = base.join("characters");
        fs::create_dir_all(&base).unwrap();
        let package = base.join("role.qipet");
        write_package(&package, "delete_me", "1.0.0", None, None);
        install_package_at(&root, &package, &[]).unwrap();

        let tombstone = move_character_to_deletion_tombstone(&root, "delete_me")
            .unwrap()
            .expect("installed role must move to a tombstone");
        assert!(!root.join("delete_me").exists());
        assert!(tombstone.is_dir());
        assert!(is_deletion_tombstone_name(
            tombstone.file_name().unwrap().to_str().unwrap()
        ));

        prepare_character_root(&root).unwrap();
        assert!(!tombstone.exists());
        assert!(!root.join("delete_me").exists());
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn first_install_keeps_schema_one_non_semver_compatibility() {
        let base = temporary_directory("legacy-version");
        let root = base.join("characters");
        fs::create_dir_all(&base).unwrap();
        let first = base.join("first.qipet");
        let update = base.join("update.qipet");
        write_package(&first, "legacy_character", "private", None, None);
        write_package(&update, "legacy_character", "2.0.0", None, None);
        assert!(install_package_at(&root, &first, &[]).is_ok());
        assert!(install_package_at(&root, &update, &[]).is_err());
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn interrupted_upgrade_restores_the_valid_previous_package() {
        let base = temporary_directory("transaction-recovery");
        let root = base.join("characters");
        fs::create_dir_all(&base).unwrap();
        let package = base.join("first.qipet");
        write_package(&package, "recoverable", "1.0.0", None, None);
        install_package_at(&root, &package, &[]).unwrap();

        let backup_name = ".backup-recoverable-1-123".to_string();
        fs::rename(root.join("recoverable"), root.join(&backup_name)).unwrap();
        let transaction = InstallTransaction {
            id: "recoverable".into(),
            staging_name: "import-1-123".into(),
            backup_name: Some(backup_name.clone()),
        };
        let journal = write_install_transaction(&root, "1-123", &transaction).unwrap();
        assert!(!root.join(".transaction-1-123.json.tmp").exists());

        recover_install_transactions(&root).unwrap();

        assert!(root.join("recoverable/manifest.json").is_file());
        assert!(!root.join(backup_name).exists());
        assert!(!journal.exists());
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn recovery_fully_decodes_the_new_package_and_restores_a_valid_backup() {
        let base = temporary_directory("transaction-corrupt-destination");
        let root = base.join("characters");
        fs::create_dir_all(&base).unwrap();
        let package = base.join("first.qipet");
        write_package(&package, "recover_corrupt", "1.0.0", None, None);
        install_package_at(&root, &package, &[]).unwrap();

        let backup_name = ".backup-recover_corrupt-1-456".to_string();
        let backup = root.join(&backup_name);
        fs::rename(root.join("recover_corrupt"), &backup).unwrap();
        let destination = root.join("recover_corrupt");
        fs::create_dir_all(destination.join("animations/idle")).unwrap();
        for relative in ["manifest.json", "frames.json", "preview.png", "icon.png"] {
            fs::copy(backup.join(relative), destination.join(relative)).unwrap();
        }
        fs::write(
            destination.join("animations/idle/idle_0001.png"),
            b"corrupt png that passes existence and size checks",
        )
        .unwrap();
        assert!(validate_transaction_package(&destination, "recover_corrupt").is_err());

        let transaction = InstallTransaction {
            id: "recover_corrupt".into(),
            staging_name: "import-1-456".into(),
            backup_name: Some(backup_name.clone()),
        };
        let journal = write_install_transaction(&root, "1-456", &transaction).unwrap();

        prepare_character_root(&root).unwrap();

        assert!(validate_transaction_package(&destination, "recover_corrupt").is_ok());
        assert!(!backup.exists());
        assert!(!journal.exists());
        assert!(!fs::read_dir(&root)
            .unwrap()
            .filter_map(Result::ok)
            .any(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".deleting-")
            }));
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn startup_cleans_only_generated_orphan_import_artifacts() {
        let base = temporary_directory("orphan-cleanup");
        let root = base.join("characters");
        let staging = root.join(".staging/import-crashed");
        fs::create_dir_all(&staging).unwrap();
        fs::write(staging.join("partial.bin"), b"partial").unwrap();
        let journal_temp = root.join(".transaction-crashed.json.tmp");
        fs::write(&journal_temp, b"{partial").unwrap();
        let unrelated = root.join("keep-me.txt");
        fs::write(&unrelated, b"keep").unwrap();
        let manual_staging = root.join(".staging/manual-data");
        fs::create_dir_all(&manual_staging).unwrap();

        prepare_character_root(&root).unwrap();

        assert!(!staging.exists());
        assert!(!journal_temp.exists());
        assert!(unrelated.is_file());
        assert!(manual_staging.is_dir());
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn traversal_and_symlink_entries_are_rejected_without_half_install() {
        for (label, extra) in [
            ("traversal", ("../escape.txt", &b"no"[..], None)),
            ("symlink", ("metadata/link", &b"target"[..], Some(0o120777))),
        ] {
            let base = temporary_directory(label);
            let root = base.join("characters");
            fs::create_dir_all(&base).unwrap();
            let package = base.join("invalid.qipet");
            write_package(&package, "safe_character", "1.0.0", None, Some(extra));
            assert!(install_package_at(&root, &package, &[]).is_err());
            assert!(!root.join("safe_character").exists());
            assert!(!base.join("escape.txt").exists());
            fs::remove_dir_all(base).unwrap();
        }
    }

    #[test]
    fn corrupt_png_and_bundled_id_collisions_are_rejected() {
        let base = temporary_directory("invalid-content");
        let root = base.join("characters");
        fs::create_dir_all(&base).unwrap();
        let corrupt = base.join("corrupt.qipet");
        let bundled = base.join("bundled.qipet");
        write_package(
            &corrupt,
            "corrupt_character",
            "1.0.0",
            Some(b"not png"),
            None,
        );
        write_package(&bundled, "official", "1.0.0", None, None);
        assert!(install_package_at(&root, &corrupt, &[]).is_err());
        assert!(install_package_at(&root, &bundled, &["OFFICIAL".into()]).is_err());
        assert!(!root.join("corrupt_character").exists());
        assert!(!root.join("official").exists());
        fs::remove_dir_all(base).unwrap();
    }
}
