fn main() {
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&[
            "set_fullscreen_auto_hide",
            "quit_app",
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
        ]),
    ))
    .expect("failed to build Tauri application permissions")
}
