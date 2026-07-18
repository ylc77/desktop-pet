mod character_catalog;
mod diagnostics;
mod updater;

use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use tauri::{
    menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    webview::PageLoadEvent,
    AppHandle, Emitter, LogicalPosition, Manager, PhysicalPosition, Position, Runtime, WebviewUrl,
    WebviewWindow, WebviewWindowBuilder, WindowEvent,
};
use tauri_plugin_autostart::MacosLauncher;
use tauri_plugin_log::RotationStrategy;

pub(crate) fn run_on_main_thread_with_result<R, T, F>(
    app: &AppHandle<R>,
    action: F,
) -> Result<T, String>
where
    R: Runtime,
    T: Send + 'static,
    F: FnOnce(AppHandle<R>) -> Result<T, String> + Send + 'static,
{
    let action_app = app.clone();
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    app.run_on_main_thread(move || {
        let _ = sender.send(action(action_app));
    })
    .map_err(|error| format!("cannot schedule window operation: {error}"))?;
    receiver
        .recv_timeout(std::time::Duration::from_secs(30))
        .map_err(|error| format!("window operation did not complete: {error}"))?
}

#[derive(Default)]
struct SettingsFileLock(Mutex<()>);

#[derive(Clone, Copy, Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct NativeMenuState {
    paused: bool,
    always_on_top: bool,
    autostart: bool,
    update_busy: bool,
}

impl Default for NativeMenuState {
    fn default() -> Self {
        Self {
            paused: false,
            always_on_top: true,
            autostart: false,
            update_busy: false,
        }
    }
}

#[derive(Default)]
struct NativeMenuStateStore(Mutex<NativeMenuState>);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SettingsSection {
    General,
    Appearance,
    Behavior,
    Update,
    About,
}

impl SettingsSection {
    fn parse(value: Option<&str>) -> Result<Self, String> {
        match value.unwrap_or("general") {
            "general" => Ok(Self::General),
            "appearance" => Ok(Self::Appearance),
            "behavior" => Ok(Self::Behavior),
            "update" => Ok(Self::Update),
            "about" => Ok(Self::About),
            _ => Err("unknown settings section".to_string()),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::General => "general",
            Self::Appearance => "appearance",
            Self::Behavior => "behavior",
            Self::Update => "update",
            Self::About => "about",
        }
    }
}

#[derive(Clone, Copy, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct SettingsNavigation {
    section: &'static str,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum NativeMenuSurface {
    Pet,
    Tray,
}

const APP_ACTION_IDS: &[&str] = &[
    "appearance",
    "settings",
    "toggle-pause",
    "hide",
    "show",
    "toggle-top",
    "toggle-autostart",
    "check-updates",
    "about",
    "reset",
    "quit",
];

fn is_app_action_id(id: &str) -> bool {
    APP_ACTION_IDS.contains(&id)
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct SettingsReadResult {
    value: Option<serde_json::Value>,
    recovered: bool,
    backup_file: Option<String>,
}

fn settings_file_path<R: Runtime>(app: &AppHandle<R>) -> Result<std::path::PathBuf, String> {
    app.path()
        .app_config_dir()
        .map(|directory| directory.join("settings.json"))
        .map_err(|error| format!("cannot resolve application config directory: {error}"))
}

fn settings_backup_name(prefix: &str) -> String {
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or_default();
    format!("settings.{prefix}-{timestamp}.json")
}

#[cfg(windows)]
fn replace_file(source: &std::path::Path, destination: &std::path::Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };

    let source_wide: Vec<u16> = source.as_os_str().encode_wide().chain(Some(0)).collect();
    let destination_wide: Vec<u16> = destination
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    let result = unsafe {
        MoveFileExW(
            source_wide.as_ptr(),
            destination_wide.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if result == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(not(windows))]
fn replace_file(source: &std::path::Path, destination: &std::path::Path) -> std::io::Result<()> {
    if destination.exists() {
        std::fs::remove_file(destination)?;
    }
    std::fs::rename(source, destination)
}

#[tauri::command]
fn read_settings_file<R: Runtime>(
    app: AppHandle<R>,
    state: tauri::State<'_, SettingsFileLock>,
) -> Result<SettingsReadResult, String> {
    let _guard = state.0.lock().map_err(|_| "settings lock poisoned")?;
    let path = settings_file_path(&app)?;
    read_settings_at_path(&path)
}

fn read_settings_at_path(path: &std::path::Path) -> Result<SettingsReadResult, String> {
    if !path.exists() {
        return Ok(SettingsReadResult {
            value: None,
            recovered: false,
            backup_file: None,
        });
    }

    let bytes = std::fs::read(&path).map_err(|error| format!("cannot read settings: {error}"))?;
    match serde_json::from_slice::<serde_json::Value>(&bytes) {
        Ok(root) => Ok(SettingsReadResult {
            value: root.get("settings").cloned(),
            recovered: false,
            backup_file: None,
        }),
        Err(error) => {
            let backup_file = settings_backup_name("corrupt");
            let backup_path = path.with_file_name(&backup_file);
            std::fs::rename(&path, &backup_path).map_err(|backup_error| {
                format!("invalid settings ({error}); backup failed: {backup_error}")
            })?;
            log::warn!("invalid settings were backed up as {backup_file}");
            Ok(SettingsReadResult {
                value: None,
                recovered: true,
                backup_file: Some(backup_file),
            })
        }
    }
}

#[tauri::command]
fn write_settings_file<R: Runtime>(
    app: AppHandle<R>,
    settings: serde_json::Value,
    state: tauri::State<'_, SettingsFileLock>,
) -> Result<(), String> {
    let _guard = state.0.lock().map_err(|_| "settings lock poisoned")?;
    let path = settings_file_path(&app)?;
    write_settings_at_path(&path, settings)
}

#[tauri::command]
fn quarantine_invalid_settings_file<R: Runtime>(
    app: AppHandle<R>,
    state: tauri::State<'_, SettingsFileLock>,
) -> Result<Option<String>, String> {
    let _guard = state.0.lock().map_err(|_| "settings lock poisoned")?;
    let path = settings_file_path(&app)?;
    if !path.exists() {
        return Ok(None);
    }
    let backup_file = settings_backup_name("invalid");
    std::fs::rename(&path, path.with_file_name(&backup_file))
        .map_err(|error| format!("cannot back up invalid settings: {error}"))?;
    log::warn!("invalid settings schema was backed up as {backup_file}");
    Ok(Some(backup_file))
}

fn write_settings_at_path(
    path: &std::path::Path,
    settings: serde_json::Value,
) -> Result<(), String> {
    let parent = path.parent().ok_or("settings path has no parent")?;
    std::fs::create_dir_all(parent)
        .map_err(|error| format!("cannot create settings directory: {error}"))?;

    let temporary = path.with_file_name("settings.json.tmp");
    let payload = serde_json::json!({ "settings": settings });
    let bytes = serde_json::to_vec_pretty(&payload)
        .map_err(|error| format!("cannot serialize settings: {error}"))?;
    let mut file = std::fs::File::create(&temporary)
        .map_err(|error| format!("cannot create temporary settings: {error}"))?;
    use std::io::Write;
    file.write_all(&bytes)
        .and_then(|_| file.sync_all())
        .map_err(|error| format!("cannot flush temporary settings: {error}"))?;
    drop(file);

    if path.exists() {
        let backup = path.with_file_name("settings.backup.json");
        std::fs::copy(&path, backup)
            .map_err(|error| format!("cannot back up previous settings: {error}"))?;
    }
    replace_file(&temporary, &path)
        .map_err(|error| format!("cannot atomically replace settings: {error}"))
}

#[derive(Clone, Default)]
struct FullscreenMonitor {
    enabled: Arc<AtomicBool>,
    auto_hidden: Arc<AtomicBool>,
}

#[derive(Clone, Copy)]
enum VisibilityReason {
    AutoHideDisabled,
    FullscreenDetected,
    FullscreenEnded,
    MainCloseRequested,
    SingleInstance,
    TrayActivate,
    TrayHide,
    TrayReset,
}

impl VisibilityReason {
    fn as_str(self) -> &'static str {
        match self {
            Self::AutoHideDisabled => "auto-hide-disabled",
            Self::FullscreenDetected => "fullscreen-detected",
            Self::FullscreenEnded => "fullscreen-ended",
            Self::MainCloseRequested => "main-close-requested",
            Self::SingleInstance => "single-instance",
            Self::TrayActivate => "tray-activate",
            Self::TrayHide => "tray-hide",
            Self::TrayReset => "tray-reset",
        }
    }
}

#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct VisibilityChanged {
    visible: bool,
    reason: &'static str,
}

fn set_native_visibility<R: Runtime>(
    window: &WebviewWindow<R>,
    visible: bool,
    reason: VisibilityReason,
) -> bool {
    let result = if visible {
        window.show()
    } else {
        window.hide()
    };
    match result {
        Ok(()) => {
            if let Err(error) = window.emit(
                "pet-visibility-changed",
                VisibilityChanged {
                    visible,
                    reason: reason.as_str(),
                },
            ) {
                log::warn!(
                    "cannot emit native visibility change (reason={}): {error}",
                    reason.as_str()
                );
            }
            true
        }
        Err(error) => {
            log::warn!(
                "cannot change native visibility to {visible} (reason={}): {error}",
                reason.as_str()
            );
            false
        }
    }
}

#[tauri::command]
fn set_fullscreen_auto_hide(enabled: bool, state: tauri::State<'_, FullscreenMonitor>) {
    state.enabled.store(enabled, Ordering::Relaxed);
}

#[tauri::command]
fn quit_app<R: Runtime>(app: AppHandle<R>) {
    app.exit(0);
}

#[tauri::command]
fn flush_application_logs() {
    log::logger().flush();
}

#[tauri::command]
fn restore_main_window<R: Runtime>(app: AppHandle<R>) {
    show_main(&app, VisibilityReason::TrayReset);
}

#[cfg(windows)]
fn foreground_is_fullscreen() -> bool {
    use windows_sys::Win32::{
        Foundation::RECT,
        Graphics::Gdi::{
            GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTONEAREST,
        },
        System::Threading::GetCurrentProcessId,
        UI::WindowsAndMessaging::{
            GetForegroundWindow, GetShellWindow, GetWindowLongPtrW, GetWindowRect,
            GetWindowThreadProcessId, IsWindowVisible, IsZoomed, GWL_STYLE, WS_CAPTION, WS_POPUP,
            WS_THICKFRAME,
        },
    };
    unsafe {
        let hwnd = GetForegroundWindow();
        if hwnd.is_null() || hwnd == GetShellWindow() || IsWindowVisible(hwnd) == 0 {
            return false;
        }
        let mut process_id = 0;
        GetWindowThreadProcessId(hwnd, &mut process_id);
        if process_id == GetCurrentProcessId() {
            return false;
        }
        let monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        if monitor.is_null() {
            return false;
        }
        let mut window_rect = RECT::default();
        let mut monitor_info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if GetWindowRect(hwnd, &mut window_rect) == 0
            || GetMonitorInfoW(monitor, &mut monitor_info) == 0
        {
            return false;
        }
        let style = GetWindowLongPtrW(hwnd, GWL_STYLE) as u32;
        is_fullscreen_candidate(
            FullscreenWindowInfo {
                window: PhysicalRect {
                    left: window_rect.left,
                    top: window_rect.top,
                    right: window_rect.right,
                    bottom: window_rect.bottom,
                },
                monitor: PhysicalRect {
                    left: monitor_info.rcMonitor.left,
                    top: monitor_info.rcMonitor.top,
                    right: monitor_info.rcMonitor.right,
                    bottom: monitor_info.rcMonitor.bottom,
                },
                work_area: PhysicalRect {
                    left: monitor_info.rcWork.left,
                    top: monitor_info.rcWork.top,
                    right: monitor_info.rcWork.right,
                    bottom: monitor_info.rcWork.bottom,
                },
                is_zoomed: IsZoomed(hwnd) != 0,
                is_popup: style & WS_POPUP != 0,
                has_window_frame: style & (WS_CAPTION | WS_THICKFRAME) != 0,
            },
            2,
        )
    }
}

#[cfg(not(windows))]
fn foreground_is_fullscreen() -> bool {
    false
}

fn start_fullscreen_monitor<R: Runtime>(app: AppHandle<R>, state: FullscreenMonitor) {
    std::thread::spawn(move || {
        let mut fullscreen_samples = 0_u8;
        let mut windowed_samples = 0_u8;
        loop {
            std::thread::sleep(std::time::Duration::from_millis(900));
            let Some(window) = app.get_webview_window("main") else {
                break;
            };
            if !state.enabled.load(Ordering::Relaxed) {
                fullscreen_samples = 0;
                windowed_samples = 0;
                if state.auto_hidden.load(Ordering::Relaxed)
                    && set_native_visibility(&window, true, VisibilityReason::AutoHideDisabled)
                {
                    state.auto_hidden.store(false, Ordering::Relaxed);
                }
                continue;
            }
            let fullscreen = foreground_is_fullscreen() && !window.is_focused().unwrap_or(false);
            if fullscreen {
                fullscreen_samples = fullscreen_samples.saturating_add(1);
                windowed_samples = 0;
                if fullscreen_samples >= 2
                    && !state.auto_hidden.load(Ordering::Relaxed)
                    && set_native_visibility(&window, false, VisibilityReason::FullscreenDetected)
                {
                    state.auto_hidden.store(true, Ordering::Relaxed);
                }
            } else {
                windowed_samples = windowed_samples.saturating_add(1);
                fullscreen_samples = 0;
                if windowed_samples >= 2
                    && state.auto_hidden.load(Ordering::Relaxed)
                    && set_native_visibility(&window, true, VisibilityReason::FullscreenEnded)
                {
                    state.auto_hidden.store(false, Ordering::Relaxed);
                }
            }
        }
    });
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct PhysicalRect {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
}

impl PhysicalRect {
    fn from_window(position: PhysicalPosition<i32>, size: tauri::PhysicalSize<u32>) -> Self {
        Self {
            left: position.x,
            top: position.y,
            right: position.x.saturating_add(size.width as i32),
            bottom: position.y.saturating_add(size.height as i32),
        }
    }

    fn width(self) -> i32 {
        self.right.saturating_sub(self.left).max(0)
    }

    fn height(self) -> i32 {
        self.bottom.saturating_sub(self.top).max(0)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FullscreenWindowInfo {
    window: PhysicalRect,
    monitor: PhysicalRect,
    work_area: PhysicalRect,
    is_zoomed: bool,
    is_popup: bool,
    has_window_frame: bool,
}

fn rect_covers(outer: PhysicalRect, inner: PhysicalRect, tolerance: i32) -> bool {
    let tolerance = tolerance.max(0);
    outer.left <= inner.left.saturating_add(tolerance)
        && outer.top <= inner.top.saturating_add(tolerance)
        && outer.right >= inner.right.saturating_sub(tolerance)
        && outer.bottom >= inner.bottom.saturating_sub(tolerance)
}

fn coordinates_match(left: i32, right: i32, tolerance: i32) -> bool {
    (left as i64 - right as i64).abs() <= tolerance.max(0) as i64
}

fn rect_matches(left: PhysicalRect, right: PhysicalRect, tolerance: i32) -> bool {
    coordinates_match(left.left, right.left, tolerance)
        && coordinates_match(left.top, right.top, tolerance)
        && coordinates_match(left.right, right.right, tolerance)
        && coordinates_match(left.bottom, right.bottom, tolerance)
}

fn is_fullscreen_candidate(candidate: FullscreenWindowInfo, tolerance: i32) -> bool {
    if !rect_covers(candidate.window, candidate.monitor, tolerance) {
        return false;
    }

    // Borderless fullscreen applications normally use WS_POPUP. Keep those
    // candidates even if Windows also reports the window as zoomed.
    if candidate.is_popup {
        return true;
    }

    // A framed, zoomed top-level window is the normal desktop maximize shape.
    // Reject it even when an auto-hidden taskbar makes work and monitor
    // rectangles identical. A frameless browser fullscreen window may still
    // report IsZoomed, so retain that candidate.
    if candidate.is_zoomed && candidate.has_window_frame {
        return false;
    }

    // This also rejects unusual non-zoomed shells constrained to the work area,
    // while retaining borderless windows that actually cover the monitor.
    !rect_matches(candidate.window, candidate.work_area, tolerance)
        || rect_matches(candidate.work_area, candidate.monitor, tolerance)
}

fn intersection_area(left: PhysicalRect, right: PhysicalRect) -> u64 {
    let width = left
        .right
        .min(right.right)
        .saturating_sub(left.left.max(right.left))
        .max(0);
    let height = left
        .bottom
        .min(right.bottom)
        .saturating_sub(left.top.max(right.top))
        .max(0);
    width as u64 * height as u64
}

fn window_is_visible_in_work_area(
    position: PhysicalPosition<i32>,
    size: tauri::PhysicalSize<u32>,
    work_area: PhysicalRect,
    visible_margin: i32,
) -> bool {
    let window = PhysicalRect::from_window(position, size);
    window.left.saturating_add(visible_margin) < work_area.right
        && window.top.saturating_add(visible_margin) < work_area.bottom
        && window.right.saturating_sub(visible_margin) > work_area.left
        && window.bottom.saturating_sub(visible_margin) > work_area.top
}

fn centered_position(
    size: tauri::PhysicalSize<u32>,
    work_area: PhysicalRect,
) -> PhysicalPosition<i32> {
    let x = work_area.left + (work_area.width().saturating_sub(size.width as i32)).max(0) / 2;
    let y = work_area.top + (work_area.height().saturating_sub(size.height as i32)).max(0) / 2;
    PhysicalPosition::new(x, y)
}

#[cfg(test)]
fn logical_to_physical(value: f64, scale_factor: f64) -> Option<i32> {
    if !value.is_finite() || !scale_factor.is_finite() || scale_factor <= 0.0 {
        return None;
    }
    let converted = value * scale_factor;
    if converted < i32::MIN as f64 || converted > i32::MAX as f64 {
        return None;
    }
    Some(converted.round() as i32)
}

#[cfg(windows)]
fn monitor_work_areas() -> Vec<(PhysicalRect, bool)> {
    use windows_sys::core::BOOL;
    use windows_sys::Win32::{
        Foundation::{LPARAM, RECT},
        Graphics::Gdi::{EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFO},
        UI::WindowsAndMessaging::MONITORINFOF_PRIMARY,
    };

    unsafe extern "system" fn collect(
        monitor: HMONITOR,
        _dc: HDC,
        _rect: *mut RECT,
        data: LPARAM,
    ) -> BOOL {
        let areas = &mut *(data as *mut Vec<(PhysicalRect, bool)>);
        let mut info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if GetMonitorInfoW(monitor, &mut info) != 0 {
            areas.push((
                PhysicalRect {
                    left: info.rcWork.left,
                    top: info.rcWork.top,
                    right: info.rcWork.right,
                    bottom: info.rcWork.bottom,
                },
                info.dwFlags & MONITORINFOF_PRIMARY != 0,
            ));
        }
        1
    }

    let mut areas = Vec::new();
    unsafe {
        EnumDisplayMonitors(
            std::ptr::null_mut(),
            std::ptr::null(),
            Some(collect),
            &mut areas as *mut _ as LPARAM,
        );
    }
    areas
}

#[cfg(not(windows))]
fn monitor_work_areas() -> Vec<(PhysicalRect, bool)> {
    Vec::new()
}

fn clamp_window_to_visible_area<R: Runtime>(window: &WebviewWindow<R>) {
    let Ok(monitors) = window.available_monitors() else {
        return;
    };
    if monitors.is_empty() {
        return;
    }
    let Ok(position) = window.outer_position() else {
        return;
    };
    let Ok(size) = window.outer_size() else {
        return;
    };
    const VISIBLE_MARGIN: i32 = 48;
    let mut work_areas = monitor_work_areas();
    if work_areas.is_empty() {
        work_areas = monitors
            .iter()
            .enumerate()
            .map(|(index, monitor)| {
                let origin = monitor.position();
                let dimensions = monitor.size();
                (
                    PhysicalRect {
                        left: origin.x,
                        top: origin.y,
                        right: origin.x.saturating_add(dimensions.width as i32),
                        bottom: origin.y.saturating_add(dimensions.height as i32),
                    },
                    index == 0,
                )
            })
            .collect();
    }

    let is_visible = work_areas
        .iter()
        .any(|(area, _)| window_is_visible_in_work_area(position, size, *area, VISIBLE_MARGIN));
    if is_visible {
        return;
    }

    let window_rect = PhysicalRect::from_window(position, size);
    let target = work_areas
        .iter()
        .max_by_key(|(area, primary)| (intersection_area(window_rect, *area), *primary as u8))
        .or_else(|| work_areas.iter().find(|(_, primary)| *primary));
    if let Some((area, _)) = target {
        let _ = window.set_position(Position::Physical(centered_position(size, *area)));
    }
}

#[cfg(test)]
mod tests {
    use super::{
        centered_position, intersection_area, is_app_action_id, is_fullscreen_candidate,
        logical_to_physical, read_settings_at_path, render_startup_diagnostic,
        sanitize_plugin_name, summarize_startup_error, window_is_visible_in_work_area,
        write_settings_at_path, FullscreenWindowInfo, PhysicalRect, SettingsSection,
    };
    use tauri::{PhysicalPosition, PhysicalSize};

    #[test]
    fn window_inside_monitor_is_visible() {
        assert!(window_is_visible_in_work_area(
            PhysicalPosition::new(100, 100),
            PhysicalSize::new(300, 300),
            PhysicalRect {
                left: 0,
                top: 0,
                right: 1920,
                bottom: 1040
            },
            48,
        ));
    }

    #[test]
    fn window_fully_outside_monitor_is_not_visible() {
        assert!(!window_is_visible_in_work_area(
            PhysicalPosition::new(2100, 100),
            PhysicalSize::new(300, 300),
            PhysicalRect {
                left: 0,
                top: 0,
                right: 1920,
                bottom: 1040
            },
            48,
        ));
    }

    #[test]
    fn minimum_visible_margin_keeps_window_recoverable() {
        assert!(window_is_visible_in_work_area(
            PhysicalPosition::new(1870, 100),
            PhysicalSize::new(300, 300),
            PhysicalRect {
                left: 0,
                top: 0,
                right: 1920,
                bottom: 1040
            },
            48,
        ));
    }

    #[test]
    fn negative_coordinate_monitor_is_supported() {
        assert!(window_is_visible_in_work_area(
            PhysicalPosition::new(-1800, -900),
            PhysicalSize::new(300, 300),
            PhysicalRect {
                left: -1920,
                top: -1080,
                right: 0,
                bottom: 0
            },
            48,
        ));
    }

    #[test]
    fn taskbar_reduced_work_area_is_respected() {
        assert!(!window_is_visible_in_work_area(
            PhysicalPosition::new(1900, 400),
            PhysicalSize::new(40, 300),
            PhysicalRect {
                left: 0,
                top: 0,
                right: 1880,
                bottom: 1080
            },
            48,
        ));
    }

    #[test]
    fn disappeared_monitor_recenters_on_remaining_work_area() {
        assert_eq!(
            centered_position(
                PhysicalSize::new(420, 420),
                PhysicalRect {
                    left: 0,
                    top: 40,
                    right: 1920,
                    bottom: 1080
                }
            ),
            PhysicalPosition::new(750, 350)
        );
    }

    #[test]
    fn extreme_window_size_uses_work_area_origin() {
        assert_eq!(
            centered_position(
                PhysicalSize::new(5000, 3000),
                PhysicalRect {
                    left: -1920,
                    top: 0,
                    right: 0,
                    bottom: 1040
                }
            ),
            PhysicalPosition::new(-1920, 0)
        );
    }

    #[test]
    fn monitor_intersection_is_deterministic() {
        let window = PhysicalRect {
            left: -100,
            top: 100,
            right: 200,
            bottom: 400,
        };
        let left = PhysicalRect {
            left: -1920,
            top: 0,
            right: 0,
            bottom: 1080,
        };
        let right = PhysicalRect {
            left: 0,
            top: 0,
            right: 1920,
            bottom: 1080,
        };
        assert_eq!(intersection_area(window, left), 30_000);
        assert_eq!(intersection_area(window, right), 60_000);
    }

    fn fullscreen_info(
        window: PhysicalRect,
        is_zoomed: bool,
        is_popup: bool,
        has_window_frame: bool,
    ) -> FullscreenWindowInfo {
        FullscreenWindowInfo {
            window,
            monitor: PhysicalRect {
                left: 0,
                top: 0,
                right: 1920,
                bottom: 1080,
            },
            work_area: PhysicalRect {
                left: 0,
                top: 0,
                right: 1920,
                bottom: 1040,
            },
            is_zoomed,
            is_popup,
            has_window_frame,
        }
    }

    #[test]
    fn ordinary_maximized_work_area_window_is_not_fullscreen() {
        assert!(!is_fullscreen_candidate(
            fullscreen_info(
                PhysicalRect {
                    left: -8,
                    top: -8,
                    right: 1928,
                    bottom: 1048,
                },
                true,
                false,
                true,
            ),
            2,
        ));
    }

    #[test]
    fn zoomed_non_popup_is_rejected_when_taskbar_auto_hides() {
        let monitor = PhysicalRect {
            left: 0,
            top: 0,
            right: 1920,
            bottom: 1080,
        };
        assert!(!is_fullscreen_candidate(
            FullscreenWindowInfo {
                window: monitor,
                monitor,
                work_area: monitor,
                is_zoomed: true,
                is_popup: false,
                has_window_frame: true,
            },
            2,
        ));
    }

    #[test]
    fn popup_fullscreen_candidate_is_retained() {
        assert!(is_fullscreen_candidate(
            fullscreen_info(
                PhysicalRect {
                    left: 0,
                    top: 0,
                    right: 1920,
                    bottom: 1080,
                },
                true,
                true,
                false,
            ),
            2,
        ));
    }

    #[test]
    fn borderless_fullscreen_candidate_is_retained() {
        assert!(is_fullscreen_candidate(
            fullscreen_info(
                PhysicalRect {
                    left: 0,
                    top: 0,
                    right: 1920,
                    bottom: 1080,
                },
                false,
                false,
                false,
            ),
            2,
        ));
    }

    #[test]
    fn zoomed_frameless_non_popup_fullscreen_candidate_is_retained() {
        assert!(is_fullscreen_candidate(
            fullscreen_info(
                PhysicalRect {
                    left: 0,
                    top: 0,
                    right: 1920,
                    bottom: 1080,
                },
                true,
                false,
                false,
            ),
            2,
        ));
    }

    #[test]
    fn fullscreen_candidate_allows_two_pixel_rounding_tolerance() {
        assert!(is_fullscreen_candidate(
            fullscreen_info(
                PhysicalRect {
                    left: 2,
                    top: 1,
                    right: 1918,
                    bottom: 1079,
                },
                false,
                true,
                false,
            ),
            2,
        ));
    }

    #[test]
    fn undersized_borderless_window_is_not_fullscreen() {
        assert!(!is_fullscreen_candidate(
            fullscreen_info(
                PhysicalRect {
                    left: 3,
                    top: 0,
                    right: 1917,
                    bottom: 1080,
                },
                false,
                true,
                false,
            ),
            2,
        ));
    }

    #[test]
    fn dpi_scale_conversion_handles_common_scales_and_invalid_values() {
        assert_eq!(logical_to_physical(100.0, 1.0), Some(100));
        assert_eq!(logical_to_physical(100.0, 1.25), Some(125));
        assert_eq!(logical_to_physical(100.0, 1.5), Some(150));
        assert_eq!(logical_to_physical(100.0, 1.75), Some(175));
        assert_eq!(logical_to_physical(100.0, 2.0), Some(200));
        assert_eq!(logical_to_physical(f64::NAN, 1.0), None);
        assert_eq!(logical_to_physical(100.0, 0.0), None);
    }

    fn temporary_settings_directory() -> std::path::PathBuf {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("desk-pet-settings-{}-{unique}", std::process::id()))
    }

    #[test]
    fn settings_write_keeps_backup_and_replaces_complete_json() {
        let directory = temporary_settings_directory();
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("settings.json");
        std::fs::write(&path, br#"{"settings":{"scale":1}}"#).unwrap();

        write_settings_at_path(&path, serde_json::json!({ "scale": 1.25 })).unwrap();

        let current: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        let backup: serde_json::Value =
            serde_json::from_slice(&std::fs::read(directory.join("settings.backup.json")).unwrap())
                .unwrap();
        assert_eq!(current["settings"]["scale"], 1.25);
        assert_eq!(backup["settings"]["scale"], 1);
        assert!(!directory.join("settings.json.tmp").exists());
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn corrupt_settings_are_moved_out_of_the_active_path() {
        let directory = temporary_settings_directory();
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("settings.json");
        std::fs::write(&path, b"{truncated").unwrap();

        let result = read_settings_at_path(&path).unwrap();

        assert!(result.recovered);
        assert!(result.value.is_none());
        assert!(!path.exists());
        assert!(directory.join(result.backup_file.unwrap()).exists());
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn invalid_utf8_settings_are_moved_out_of_the_active_path() {
        let directory = temporary_settings_directory();
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("settings.json");
        std::fs::write(&path, [0xff, 0xfe, 0x00, 0x7b]).unwrap();

        let result = read_settings_at_path(&path).unwrap();

        assert!(result.recovered);
        assert!(result.value.is_none());
        assert!(!path.exists());
        assert!(directory.join(result.backup_file.unwrap()).exists());
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn startup_plugin_errors_are_reduced_to_non_sensitive_diagnostics() {
        let error = tauri::Error::PluginInitialization(
            "updater".to_string(),
            r#"secret=C:\Users\someone\private.key; token=do-not-log"#.to_string(),
        );
        let summary = summarize_startup_error(&error);
        let diagnostic = render_startup_diagnostic(&summary);

        assert_eq!(summary.category, "plugin_initialization");
        assert_eq!(summary.plugin, "updater");
        assert!(diagnostic.contains("applicationVersion="));
        assert!(!diagnostic.contains("Users"));
        assert!(!diagnostic.contains("private.key"));
        assert!(!diagnostic.contains("do-not-log"));
    }

    #[test]
    fn unexpected_plugin_names_are_redacted() {
        assert_eq!(sanitize_plugin_name("updater"), "updater");
        assert_eq!(
            sanitize_plugin_name(r#"C:\Users\someone\plugin"#),
            "unknown"
        );
        assert_eq!(sanitize_plugin_name(""), "unknown");
    }

    #[test]
    fn settings_sections_are_strictly_whitelisted() {
        for section in ["general", "appearance", "behavior", "update", "about"] {
            assert_eq!(
                SettingsSection::parse(Some(section)).unwrap().as_str(),
                section
            );
        }
        assert_eq!(
            SettingsSection::parse(None).unwrap(),
            SettingsSection::General
        );
        assert!(SettingsSection::parse(Some("developer")).is_err());
        assert!(SettingsSection::parse(Some("../about")).is_err());
    }

    #[test]
    fn native_menu_dispatch_only_accepts_known_actions() {
        for action in [
            "appearance",
            "settings",
            "toggle-pause",
            "hide",
            "show",
            "toggle-top",
            "toggle-autostart",
            "check-updates",
            "about",
            "reset",
            "quit",
        ] {
            assert!(is_app_action_id(action));
        }
        assert!(!is_app_action_id("developer"));
        assert!(!is_app_action_id("unknown"));
    }
}

fn show_main<R: Runtime>(app: &AppHandle<R>, reason: VisibilityReason) {
    if let Some(window) = app.get_webview_window("main") {
        clamp_window_to_visible_area(&window);
        if set_native_visibility(&window, true, reason) {
            if let Err(error) = window.set_focus() {
                log::warn!(
                    "cannot focus main window (reason={}): {error}",
                    reason.as_str()
                );
            }
        }
    }
}

fn show_settings_window_for<R: Runtime>(
    app: &AppHandle<R>,
    section: SettingsSection,
) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("settings") {
        window
            .unminimize()
            .map_err(|error| format!("cannot restore settings window: {error}"))?;
        window
            .show()
            .map_err(|error| format!("cannot show settings window: {error}"))?;
        clamp_window_to_visible_area(&window);
        window
            .set_focus()
            .map_err(|error| format!("cannot focus settings window: {error}"))?;
        window
            .emit(
                "settings-navigate",
                SettingsNavigation {
                    section: section.as_str(),
                },
            )
            .map_err(|error| format!("cannot navigate settings window: {error}"))?;
        return Ok(());
    }

    let initial_section = section.as_str();
    WebviewWindowBuilder::new(
        app,
        "settings",
        WebviewUrl::App(format!("index.html?surface=settings&section={initial_section}").into()),
    )
    .title("七酱桌宠 · 设置")
    .inner_size(760.0, 600.0)
    .min_inner_size(560.0, 360.0)
    .max_inner_size(960.0, 760.0)
    .resizable(true)
    .maximizable(false)
    .decorations(true)
    .transparent(false)
    .always_on_top(false)
    .skip_taskbar(false)
    .center()
    .on_page_load(move |window, payload| {
        if matches!(payload.event(), PageLoadEvent::Finished) {
            if let Err(error) = window.emit(
                "settings-navigate",
                SettingsNavigation {
                    section: initial_section,
                },
            ) {
                log::warn!("cannot deliver initial settings section: {error}");
            }
        }
    })
    .build()
    .map(|_| ())
    .map_err(|error| format!("cannot create settings window: {error}"))
}

// WebView2 window creation must not run inline on the IPC event thread. On
// Windows that can leave the new webview at about:blank while `build()` waits
// for the same event loop to finish initialization.
#[tauri::command(async)]
fn show_settings_window<R: Runtime>(
    app: AppHandle<R>,
    section: Option<String>,
) -> Result<(), String> {
    let section = SettingsSection::parse(section.as_deref())?;
    run_on_main_thread_with_result(&app, move |app| show_settings_window_for(&app, section))
}

fn native_menu_state<R: Runtime>(app: &AppHandle<R>) -> NativeMenuState {
    *app.state::<NativeMenuStateStore>()
        .0
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn main_window_is_visible<R: Runtime>(app: &AppHandle<R>) -> bool {
    app.get_webview_window("main")
        .and_then(|window| window.is_visible().ok())
        .unwrap_or(false)
}

fn build_native_menu<R: Runtime>(
    app: &AppHandle<R>,
    surface: NativeMenuSurface,
    state: NativeMenuState,
) -> tauri::Result<Menu<R>> {
    let appearance = MenuItem::with_id(app, "appearance", "外观中心", true, None::<&str>)?;
    let settings = MenuItem::with_id(app, "settings", "设置", true, None::<&str>)?;
    let pause = CheckMenuItem::with_id(
        app,
        "toggle-pause",
        "暂停动画",
        true,
        state.paused,
        None::<&str>,
    )?;
    let top = CheckMenuItem::with_id(
        app,
        "toggle-top",
        "始终置顶",
        true,
        state.always_on_top,
        None::<&str>,
    )?;
    let autostart = CheckMenuItem::with_id(
        app,
        "toggle-autostart",
        "开机启动",
        true,
        state.autostart,
        None::<&str>,
    )?;
    let check_updates = MenuItem::with_id(
        app,
        "check-updates",
        if state.update_busy {
            "更新正在进行"
        } else {
            "检查更新"
        },
        !state.update_busy,
        None::<&str>,
    )?;
    let about = MenuItem::with_id(app, "about", "关于七酱桌宠", true, None::<&str>)?;
    let reset = MenuItem::with_id(app, "reset", "恢复默认位置", true, None::<&str>)?;
    let visible = main_window_is_visible(app);
    let visibility = MenuItem::with_id(
        app,
        if visible { "hide" } else { "show" },
        if visible {
            "隐藏桌宠"
        } else {
            "显示桌宠"
        },
        true,
        None::<&str>,
    )?;
    let quit = MenuItem::with_id(
        app,
        "quit",
        if state.update_busy {
            "更新安装中，暂不可退出"
        } else {
            "退出七酱桌宠"
        },
        !state.update_busy,
        None::<&str>,
    )?;
    let separator_one = PredefinedMenuItem::separator(app)?;
    let separator_two = PredefinedMenuItem::separator(app)?;
    let separator_three = PredefinedMenuItem::separator(app)?;

    match surface {
        NativeMenuSurface::Pet => Menu::with_items(
            app,
            &[
                &appearance,
                &settings,
                &separator_one,
                &pause,
                &visibility,
                &separator_two,
                &autostart,
                &check_updates,
                &about,
                &separator_three,
                &quit,
            ],
        ),
        NativeMenuSurface::Tray => Menu::with_items(
            app,
            &[
                &visibility,
                &appearance,
                &settings,
                &separator_one,
                &pause,
                &top,
                &autostart,
                &separator_two,
                &check_updates,
                &about,
                &separator_three,
                &reset,
                &quit,
            ],
        ),
    }
}

fn refresh_tray_menu<R: Runtime>(app: &AppHandle<R>) -> Result<(), String> {
    let menu = build_native_menu(app, NativeMenuSurface::Tray, native_menu_state(app))
        .map_err(|error| format!("cannot build tray menu: {error}"))?;
    let tray = app
        .tray_by_id("main-tray")
        .ok_or_else(|| "main tray is not available".to_string())?;
    tray.set_menu(Some(menu))
        .map_err(|error| format!("cannot refresh tray menu: {error}"))
}

#[tauri::command]
fn sync_native_menu_state<R: Runtime>(
    app: AppHandle<R>,
    state: NativeMenuState,
) -> Result<(), String> {
    *app.state::<NativeMenuStateStore>()
        .0
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = state;
    refresh_tray_menu(&app)
}

#[tauri::command]
fn show_pet_context_menu<R: Runtime>(
    app: AppHandle<R>,
    window: WebviewWindow<R>,
    x: f64,
    y: f64,
    state: NativeMenuState,
) -> Result<(), String> {
    if window.label() != "main" {
        return Err("pet context menu is only available from the main window".to_string());
    }
    if !x.is_finite() || !y.is_finite() {
        return Err("pet context menu position must be finite".to_string());
    }

    *app.state::<NativeMenuStateStore>()
        .0
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = state;
    if let Err(error) = refresh_tray_menu(&app) {
        log::warn!("cannot synchronize tray menu before context popup: {error}");
    }

    let scale_factor = window
        .scale_factor()
        .map_err(|error| format!("cannot read context menu scale factor: {error}"))?;
    let size: tauri::LogicalSize<f64> = window
        .inner_size()
        .map_err(|error| format!("cannot read context menu window size: {error}"))?
        .to_logical(scale_factor);
    let position = Position::Logical(LogicalPosition::new(
        x.clamp(0.0, size.width),
        y.clamp(0.0, size.height),
    ));
    let menu = build_native_menu(&app, NativeMenuSurface::Pet, state)
        .map_err(|error| format!("cannot build pet context menu: {error}"))?;
    window
        .popup_menu_at(&menu, position)
        .map_err(|error| format!("cannot show pet context menu: {error}"))
}

fn dispatch_app_action<R: Runtime>(app: &AppHandle<R>, action: &str) {
    if !is_app_action_id(action) {
        log::warn!("ignored unknown native menu action");
        return;
    }

    match action {
        "hide" => {
            if let Some(window) = app.get_webview_window("main") {
                set_native_visibility(&window, false, VisibilityReason::TrayHide);
            }
        }
        "show" => show_main(app, VisibilityReason::TrayActivate),
        _ => {}
    }

    if let Err(error) = app.emit_to("main", "app-action", action) {
        log::warn!("cannot deliver native menu action to main window: {error}");
    }
}

fn build_tray<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<()> {
    let menu = build_native_menu(app, NativeMenuSurface::Tray, native_menu_state(app))?;

    let mut builder = TrayIconBuilder::with_id("main-tray")
        .menu(&menu)
        .tooltip("七酱桌宠")
        .show_menu_on_left_click(false)
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                show_main(tray.app_handle(), VisibilityReason::TrayActivate);
            }
        });
    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }
    builder.build(app)?;
    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
struct StartupErrorSummary {
    category: &'static str,
    plugin: String,
}

fn sanitize_plugin_name(plugin: &str) -> String {
    let trimmed = plugin.trim();
    if trimmed.is_empty()
        || trimmed.len() > 48
        || !trimmed
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_'))
    {
        "unknown".to_string()
    } else {
        trimmed.to_string()
    }
}

fn summarize_startup_error(error: &tauri::Error) -> StartupErrorSummary {
    match error {
        tauri::Error::PluginInitialization(plugin, _) => StartupErrorSummary {
            category: "plugin_initialization",
            plugin: sanitize_plugin_name(plugin),
        },
        _ => StartupErrorSummary {
            category: "tauri_run_error",
            plugin: "none".to_string(),
        },
    }
}

fn render_startup_diagnostic(summary: &StartupErrorSummary) -> String {
    format!(
        "category={}\napplicationVersion={}\nplugin={}\n",
        summary.category,
        env!("CARGO_PKG_VERSION"),
        summary.plugin
    )
}

fn write_early_startup_diagnostic(error: &tauri::Error) {
    let summary = summarize_startup_error(error);
    let directory = std::env::temp_dir().join("qijiang-desktop-pet");
    if std::fs::create_dir_all(&directory).is_ok() {
        let _ = std::fs::write(
            directory.join("startup-error.log"),
            render_startup_diagnostic(&summary),
        );
    }
}

#[cfg(windows)]
fn show_startup_error_message() {
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        MessageBoxW, MB_ICONERROR, MB_OK, MB_SETFOREGROUND,
    };

    let message: Vec<u16> = "七酱桌宠启动失败，请查看启动诊断日志。"
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let title: Vec<u16> = "七酱桌宠"
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            message.as_ptr(),
            title.as_ptr(),
            MB_OK | MB_ICONERROR | MB_SETFOREGROUND,
        );
    }
}

#[cfg(not(windows))]
fn show_startup_error_message() {}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let fullscreen_monitor = FullscreenMonitor::default();
    let result = tauri::Builder::default()
        .manage(fullscreen_monitor.clone())
        .manage(SettingsFileLock::default())
        .manage(NativeMenuStateStore::default())
        .manage(character_catalog::CharacterCatalogLock::default())
        .manage(character_catalog::ActiveCharacterState::default())
        .manage(updater::UpdaterState::default())
        .invoke_handler(tauri::generate_handler![
            set_fullscreen_auto_hide,
            quit_app,
            flush_application_logs,
            restore_main_window,
            show_settings_window,
            show_pet_context_menu,
            sync_native_menu_state,
            read_settings_file,
            write_settings_file,
            quarantine_invalid_settings_file,
            character_catalog::list_installed_characters,
            character_catalog::load_installed_character,
            character_catalog::import_character_package,
            character_catalog::remove_installed_character,
            character_catalog::get_selected_character_id,
            character_catalog::set_active_character_id,
            character_catalog::begin_character_activation,
            character_catalog::commit_character_selection,
            character_catalog::finalize_character_selection,
            character_catalog::cancel_character_selection,
            character_catalog::request_character_selection,
            character_catalog::show_appearance_window,
            updater::get_updater_configuration,
            updater::check_for_update,
            updater::download_update,
            updater::install_update,
            updater::cancel_pending_update,
            diagnostics::open_log_directory,
            diagnostics::export_diagnostics
        ])
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            show_main(app, VisibilityReason::SingleInstance)
        }))
        .plugin(
            tauri_plugin_log::Builder::new()
                .level(log::LevelFilter::Info)
                .max_file_size(1_048_576)
                .rotation_strategy(RotationStrategy::KeepSome(5))
                .build(),
        )
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            None,
        ))
        .on_menu_event(|app, event| dispatch_app_action(app, event.id.as_ref()))
        .setup(move |app| {
            build_tray(app.handle())?;
            if let Some(window) = app.get_webview_window("main") {
                clamp_window_to_visible_area(&window);
            }
            start_fullscreen_monitor(app.handle().clone(), fullscreen_monitor.clone());
            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" {
                    api.prevent_close();
                    if let Some(webview) = window.app_handle().get_webview_window("main") {
                        set_native_visibility(
                            &webview,
                            false,
                            VisibilityReason::MainCloseRequested,
                        );
                    }
                }
                return;
            }
            if matches!(
                event,
                WindowEvent::Moved(_)
                    | WindowEvent::Resized(_)
                    | WindowEvent::Focused(true)
                    | WindowEvent::ScaleFactorChanged { .. }
            ) {
                if let Some(webview) = window.app_handle().get_webview_window(window.label()) {
                    clamp_window_to_visible_area(&webview);
                }
            }
        })
        .run(tauri::generate_context!());
    if let Err(error) = result {
        write_early_startup_diagnostic(&error);
        show_startup_error_message();
        std::process::exit(1);
    }
}
