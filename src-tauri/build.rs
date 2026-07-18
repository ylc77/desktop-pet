fn main() {
    for variable in [
        "QIJIANG_UPDATER_ENDPOINT",
        "QIJIANG_UPDATER_PUBLIC_KEY",
        "QIJIANG_UPDATER_CHANNEL",
        "QIJIANG_INSTALLER_SHA256",
    ] {
        println!("cargo:rerun-if-env-changed={variable}");
    }
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&[
            "set_fullscreen_auto_hide",
            "quit_app",
            "flush_application_logs",
            "restore_main_window",
            "show_settings_window",
            "show_pet_context_menu",
            "sync_native_menu_state",
            "read_settings_file",
            "write_settings_file",
            "quarantine_invalid_settings_file",
            "list_installed_characters",
            "load_installed_character",
            "import_character_package",
            "remove_installed_character",
            "get_selected_character_id",
            "set_active_character_id",
            "begin_character_activation",
            "commit_character_selection",
            "finalize_character_selection",
            "cancel_character_selection",
            "request_character_selection",
            "show_appearance_window",
            "get_updater_configuration",
            "check_for_update",
            "download_update",
            "install_update",
            "cancel_pending_update",
            "open_log_directory",
            "export_diagnostics",
        ]),
    ))
    .expect("failed to build Tauri application permissions")
}
