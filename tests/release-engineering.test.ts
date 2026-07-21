import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const root = resolve(import.meta.dirname, "..");

describe("release engineering safeguards", () => {
  it("uses the documented WebView2 bootstrapper policy", () => {
    const config = JSON.parse(readFileSync(resolve(root, "src-tauri/tauri.conf.json"), "utf8"));
    expect(config.bundle.windows.webviewInstallMode).toEqual({ type: "downloadBootstrapper", silent: true });
  });

  it("fails release builds through the environment-aware wrapper", () => {
    const packageJson = JSON.parse(readFileSync(resolve(root, "package.json"), "utf8"));
    expect(packageJson.scripts["build:release"]).toContain("scripts/build-release.ps1");
    for (const name of ["build:release", "package:character", "check:windows-env", "release:manifest", "qa:safe", "qa:public-beta:audit"]) {
      expect(packageJson.scripts[name], name).toMatch(/^pwsh\s/);
    }
    const wrapper = readFileSync(resolve(root, "scripts/build-release.ps1"), "utf8");
    expect(wrapper).toContain("Get-Command $commandName");
    expect(wrapper).not.toMatch(/C:\\Users\\[^%]/i);

    const manifestScript = readFileSync(resolve(root, "scripts/create-release-manifest.ps1"), "utf8");
    expect(manifestScript).toContain("git -C $repo status --porcelain --untracked-files=normal");
    expect(manifestScript).not.toMatch(/--untracked-files=no(?:\s|$)/);
    expect(manifestScript).toContain("[System.Security.Cryptography.SHA256]::Create()");
    expect(manifestScript).not.toContain("Get-FileHash");

    const dispatcher = readFileSync(resolve(root, "scripts/windows/run-qa-suite.ps1"), "utf8");
    expect(dispatcher).toContain("powershell.exe -NoProfile");
  });

  it("limits native log files and atomically replaces settings", () => {
    const rust = readFileSync(resolve(root, "src-tauri/src/lib.rs"), "utf8");
    expect(rust).toContain("RotationStrategy::KeepSome(5)");
    expect(rust).toContain(".max_file_size(1_048_576)");
    expect(rust).toContain("MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH");
    expect(rust).toContain("settings.backup.json");
  });

  it("ships all Windows diagnostic and smoke-test entry points", () => {
    const files = [
      "scripts/check-windows-env.ps1",
      "scripts/create-release-manifest.ps1",
      "scripts/windows/install-smoke-test.ps1",
      "scripts/windows/uninstall-smoke-test.ps1",
      "scripts/windows/process-smoke-test.ps1",
      "scripts/windows/startup-smoke-test.ps1",
      "scripts/windows/dynamic-window-smoke-test.mjs",
      "scripts/windows/check-autostart.ps1",
      "scripts/windows/check-leftovers.ps1",
      "scripts/windows/monitor-process.ps1",
    ];
    for (const file of files) expect(existsSync(resolve(root, file)), file).toBe(true);
    expect(readFileSync(resolve(root, "scripts/windows/install-smoke-test.ps1"), "utf8")).toContain("SupportsShouldProcess");
    expect(readFileSync(resolve(root, "scripts/windows/uninstall-smoke-test.ps1"), "utf8")).toContain("SupportsShouldProcess");
  });

  it("creates secondary WebView2 windows outside the synchronous IPC event thread", () => {
    const rust = readFileSync(resolve(root, "src-tauri/src/lib.rs"), "utf8");
    const catalog = readFileSync(resolve(root, "src-tauri/src/character_catalog.rs"), "utf8");
    expect(rust).toMatch(/#\[tauri::command\(async\)\]\s*fn show_settings_window/);
    expect(catalog).toMatch(/#\[tauri::command\(async\)\]\s*pub fn show_appearance_window/);
    expect(rust).toContain("run_on_main_thread_with_result(&app");
    expect(catalog).toContain("run_on_main_thread_with_result(&app");
  });

  it("does not let Vite watch Rust build output on Windows", () => {
    const vite = readFileSync(resolve(root, "vite.config.ts"), "utf8");
    expect(vite).toContain('"**/src-tauri/target/**"');
  });

  it("runs a rendered secondary-window smoke test in Safe QA", () => {
    const dispatcher = readFileSync(resolve(root, "scripts/windows/run-qa-suite.ps1"), "utf8");
    const smoke = readFileSync(resolve(root, "scripts/windows/dynamic-window-smoke-test.mjs"), "utf8");
    expect(dispatcher).toContain("Secondary window render smoke test");
    expect(smoke).toContain("show_settings_window");
    expect(smoke).toContain("show_appearance_window");
    expect(smoke).toContain("aboutBlankTargetCount");
    expect(smoke).toContain("settingsClosed");
    expect(smoke).toContain("appearanceClosed");
    expect(smoke).toContain("plugin:window|close");
  });

  it("debounces monitor recovery after continuous pet movement", () => {
    const rust = readFileSync(resolve(root, "src-tauri/src/lib.rs"), "utf8");
    const recoveryStart = rust.indexOf("Walking and dragging can emit dozens");
    const recoveryEnd = rust.indexOf(".run(tauri::generate_context!())", recoveryStart);
    const recovery = rust.slice(recoveryStart, recoveryEnd);
    expect(recoveryStart).toBeGreaterThanOrEqual(0);
    expect(rust).toContain("MOVE_RECOVERY_QUIET_PERIOD_MS: u64 = 250");
    expect(recovery).toContain("schedule_main_window_recovery(window.app_handle())");
    expect(rust).toContain("WindowEvent::Moved(_)");
    expect(recovery).toContain("WindowEvent::Focused(_)");
  });

  it("keeps developer diagnostics behind the production build gate", () => {
    const settings = readFileSync(resolve(root, "src/core/settings/settingsSchema.ts"), "utf8");
    const app = readFileSync(resolve(root, "src/app/App.tsx"), "utf8");
    expect(settings).toContain("import.meta.env.DEV || import.meta.env.VITE_ENABLE_DEVELOPER_TOOLS === \"true\"");
    expect(app).toContain("DEVELOPER_TOOLS_ALLOWED && settings.developerPanel");
  });

  it("ships a proprietary source license, third-party notices, and auditable bundled-asset rights", () => {
    const license = readFileSync(resolve(root, "LICENSE"), "utf8");
    const notices = readFileSync(resolve(root, "THIRD_PARTY_NOTICES.md"), "utf8");
    const aggregate = readFileSync(resolve(root, "THIRD_PARTY_LICENSES.txt"), "utf8");
    const rights = readFileSync(resolve(root, "docs/ASSET_RIGHTS.md"), "utf8");
    const placeholderLicense = readFileSync(resolve(root, "public/characters/_placeholder/metadata/license.md"), "utf8");
    const packageJson = JSON.parse(readFileSync(resolve(root, "package.json"), "utf8"));
    const cargo = readFileSync(resolve(root, "src-tauri/Cargo.toml"), "utf8");

    expect(packageJson.license).toBe("UNLICENSED");
    expect(cargo).toContain('license-file = "../LICENSE"');
    expect(license).toContain("All rights reserved");
    expect(license).toContain("不得复制、修改");
    expect(notices).toContain("@tauri-apps/api");
    expect(notices).toContain("tauri-plugin-updater");
    expect(notices).toContain("THIRD_PARTY_LICENSES.txt");
    expect(notices).toContain("SPDX License List 3.28.0");
    expect(notices).toContain("WebView2 Runtime");
    expect(notices).toContain("系统字体");
    expect(rights).toContain("随公开测试安装包复制和分发");
    expect(rights).toContain("不授权把白猫照片改编为正式桌宠角色");
    expect(placeholderLicense).toContain("随七酱桌宠公开测试安装包复制和分发");
    expect(aggregate).toContain("SPDX-License-List-Version: 3.28.0");
    expect(aggregate.match(/^=== PACKAGE BEGIN ===$/gm)?.length).toBeGreaterThan(500);
    expect([license, notices, aggregate, rights, placeholderLicense].join("\n")).not.toMatch(/F:\\STAGE|C:\\Users\\77/i);

    const validator = readFileSync(resolve(root, "scripts/validate-third-party-licenses.mjs"), "utf8");
    const aggregateBuilder = readFileSync(resolve(root, "scripts/licenses/license-aggregate.mjs"), "utf8");
    expect(packageJson.scripts["validate:licenses"]).toContain("validate-third-party-licenses.mjs");
    expect(packageJson.scripts["generate:licenses"]).toContain("generate-third-party-licenses.mjs");
    expect(packageJson.scripts.validate).toContain("validate:licenses");
    expect(packageJson.scripts.build).toContain("validate:licenses");
    expect(validator).toContain("buildThirdPartyLicenseAggregate");
    expect(validator).toContain("bundle.resources");
    expect(aggregateBuilder).toContain('"--offline"');
    expect(aggregateBuilder).toContain("Cached archive checksum does not match Cargo.lock");
    expect(aggregateBuilder).not.toMatch(/\bfetch\s*\(|https?\.request\s*\(/);
  });
});
