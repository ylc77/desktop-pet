use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem, Submenu},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, Manager, PhysicalPosition, Position, Runtime, WebviewWindow, WindowEvent,
};
use tauri_plugin_autostart::MacosLauncher;
use tauri_plugin_log::RotationStrategy;

#[derive(Default)]
struct SettingsFileLock(Mutex<()>);

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

#[tauri::command]
fn set_fullscreen_auto_hide(enabled: bool, state: tauri::State<'_, FullscreenMonitor>) {
    state.enabled.store(enabled, Ordering::Relaxed);
}

#[tauri::command]
fn quit_app<R: Runtime>(app: AppHandle<R>) {
    app.exit(0);
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
            GetForegroundWindow, GetShellWindow, GetWindowRect, GetWindowThreadProcessId,
            IsWindowVisible,
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
        let screen = monitor_info.rcMonitor;
        window_rect.left <= screen.left
            && window_rect.top <= screen.top
            && window_rect.right >= screen.right
            && window_rect.bottom >= screen.bottom
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
                if state.auto_hidden.swap(false, Ordering::Relaxed) {
                    let _ = window.show();
                }
                continue;
            }
            let fullscreen = foreground_is_fullscreen() && !window.is_focused().unwrap_or(false);
            if fullscreen {
                fullscreen_samples = fullscreen_samples.saturating_add(1);
                windowed_samples = 0;
                if fullscreen_samples >= 2 && !state.auto_hidden.swap(true, Ordering::Relaxed) {
                    let _ = window.hide();
                }
            } else {
                windowed_samples = windowed_samples.saturating_add(1);
                fullscreen_samples = 0;
                if windowed_samples >= 2 && state.auto_hidden.swap(false, Ordering::Relaxed) {
                    let _ = window.show();
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
        centered_position, intersection_area, logical_to_physical, read_settings_at_path,
        window_is_visible_in_work_area, write_settings_at_path, PhysicalRect,
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
}

fn show_main<R: Runtime>(app: &AppHandle<R>) {
    if let Some(window) = app.get_webview_window("main") {
        clamp_window_to_visible_area(&window);
        let _ = window.show();
        let _ = window.set_focus();
    }
}

fn build_tray<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<()> {
    let pause = MenuItem::with_id(app, "toggle-pause", "暂停 / 继续动画", true, None::<&str>)?;
    let smaller = MenuItem::with_id(app, "smaller", "缩小", true, None::<&str>)?;
    let larger = MenuItem::with_id(app, "larger", "放大", true, None::<&str>)?;
    let size = Submenu::with_items(app, "大小", true, &[&smaller, &larger])?;
    let opacity_half = MenuItem::with_id(app, "opacity-half", "50%", true, None::<&str>)?;
    let opacity_full = MenuItem::with_id(app, "opacity-full", "100%", true, None::<&str>)?;
    let opacity = Submenu::with_items(app, "透明度", true, &[&opacity_half, &opacity_full])?;
    let top = MenuItem::with_id(app, "toggle-top", "切换置顶", true, None::<&str>)?;
    let autostart = MenuItem::with_id(app, "toggle-autostart", "切换开机启动", true, None::<&str>)?;
    let character = MenuItem::with_id(app, "character", "切换角色 / 皮肤", true, None::<&str>)?;
    let settings = MenuItem::with_id(app, "settings", "设置", true, None::<&str>)?;
    let reload = MenuItem::with_id(app, "reload", "重新加载角色资源", true, None::<&str>)?;
    let reset = MenuItem::with_id(app, "reset", "恢复默认位置", true, None::<&str>)?;
    let hide = MenuItem::with_id(app, "hide", "临时隐藏", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "退出七酱桌宠", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let menu = Menu::with_items(
        app,
        &[
            &pause, &size, &opacity, &top, &autostart, &character, &settings, &reload, &reset,
            &hide, &separator, &quit,
        ],
    )?;

    let mut builder = TrayIconBuilder::with_id("main-tray")
        .menu(&menu)
        .tooltip("七酱桌宠")
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "quit" => app.exit(0),
            "hide" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.hide();
                }
            }
            "reset" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.set_position(Position::Physical(PhysicalPosition::new(40, 40)));
                    show_main(app);
                }
            }
            action => {
                let _ = app.emit("tray-action", action);
            }
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                show_main(tray.app_handle());
            }
        });
    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }
    builder.build(app)?;
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let fullscreen_monitor = FullscreenMonitor::default();
    tauri::Builder::default()
        .manage(fullscreen_monitor.clone())
        .manage(SettingsFileLock::default())
        .invoke_handler(tauri::generate_handler![
            set_fullscreen_auto_hide,
            quit_app,
            read_settings_file,
            write_settings_file,
            quarantine_invalid_settings_file
        ])
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            show_main(app)
        }))
        .plugin(
            tauri_plugin_log::Builder::new()
                .level(log::LevelFilter::Info)
                .max_file_size(1_048_576)
                .rotation_strategy(RotationStrategy::KeepSome(5))
                .build(),
        )
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            None,
        ))
        .setup(move |app| {
            build_tray(app.handle())?;
            if let Some(window) = app.get_webview_window("main") {
                clamp_window_to_visible_area(&window);
            }
            start_fullscreen_monitor(app.handle().clone(), fullscreen_monitor.clone());
            Ok(())
        })
        .on_window_event(|window, event| {
            if matches!(
                event,
                WindowEvent::Moved(_) | WindowEvent::ScaleFactorChanged { .. }
            ) {
                if let Some(webview) = window.app_handle().get_webview_window(window.label()) {
                    clamp_window_to_visible_area(&webview);
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("failed to run 七酱桌宠");
}
