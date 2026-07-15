use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem, Submenu},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, Manager, PhysicalPosition, Position, Runtime, WebviewWindow, WindowEvent,
};
use tauri_plugin_autostart::MacosLauncher;

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

fn window_is_visible_on_monitor(
    position: PhysicalPosition<i32>,
    size: tauri::PhysicalSize<u32>,
    monitor_position: PhysicalPosition<i32>,
    monitor_size: tauri::PhysicalSize<u32>,
    visible_margin: i32,
) -> bool {
    let right = monitor_position.x + monitor_size.width as i32;
    let bottom = monitor_position.y + monitor_size.height as i32;
    position.x + visible_margin < right
        && position.y + visible_margin < bottom
        && position.x + size.width as i32 - visible_margin > monitor_position.x
        && position.y + size.height as i32 - visible_margin > monitor_position.y
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

    let is_visible = monitors.iter().any(|monitor| {
        window_is_visible_on_monitor(
            position,
            size,
            *monitor.position(),
            *monitor.size(),
            VISIBLE_MARGIN,
        )
    });
    if is_visible {
        return;
    }

    let target = window
        .current_monitor()
        .ok()
        .flatten()
        .or_else(|| window.primary_monitor().ok().flatten())
        .or_else(|| monitors.into_iter().next());
    if let Some(monitor) = target {
        let origin = monitor.position();
        let dimensions = monitor.size();
        let x = origin.x + (dimensions.width as i32 - size.width as i32).max(0) / 2;
        let y = origin.y + (dimensions.height as i32 - size.height as i32).max(0) / 2;
        let _ = window.set_position(Position::Physical(PhysicalPosition::new(x, y)));
    }
}

#[cfg(test)]
mod tests {
    use super::window_is_visible_on_monitor;
    use tauri::{PhysicalPosition, PhysicalSize};

    #[test]
    fn window_inside_monitor_is_visible() {
        assert!(window_is_visible_on_monitor(
            PhysicalPosition::new(100, 100),
            PhysicalSize::new(300, 300),
            PhysicalPosition::new(0, 0),
            PhysicalSize::new(1920, 1080),
            48,
        ));
    }

    #[test]
    fn window_fully_outside_monitor_is_not_visible() {
        assert!(!window_is_visible_on_monitor(
            PhysicalPosition::new(2100, 100),
            PhysicalSize::new(300, 300),
            PhysicalPosition::new(0, 0),
            PhysicalSize::new(1920, 1080),
            48,
        ));
    }

    #[test]
    fn minimum_visible_margin_keeps_window_recoverable() {
        assert!(window_is_visible_on_monitor(
            PhysicalPosition::new(1870, 100),
            PhysicalSize::new(300, 300),
            PhysicalPosition::new(0, 0),
            PhysicalSize::new(1920, 1080),
            48,
        ));
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
    let quit = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
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
        .tooltip("桌宠框架")
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
        .invoke_handler(tauri::generate_handler![set_fullscreen_auto_hide, quit_app])
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            show_main(app)
        }))
        .plugin(tauri_plugin_store::Builder::new().build())
        .plugin(
            tauri_plugin_log::Builder::new()
                .level(log::LevelFilter::Info)
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
        .expect("failed to run desktop pet framework");
}
