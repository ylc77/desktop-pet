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
    const wrapper = readFileSync(resolve(root, "scripts/build-release.ps1"), "utf8");
    expect(wrapper).toContain("Get-Command $commandName");
    expect(wrapper).not.toMatch(/C:\\Users\\[^%]/i);
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
      "scripts/windows/check-autostart.ps1",
      "scripts/windows/check-leftovers.ps1",
      "scripts/windows/monitor-process.ps1",
    ];
    for (const file of files) expect(existsSync(resolve(root, file)), file).toBe(true);
    expect(readFileSync(resolve(root, "scripts/windows/install-smoke-test.ps1"), "utf8")).toContain("SupportsShouldProcess");
    expect(readFileSync(resolve(root, "scripts/windows/uninstall-smoke-test.ps1"), "utf8")).toContain("SupportsShouldProcess");
  });
});
