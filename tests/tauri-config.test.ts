import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("Tauri window capabilities", () => {
  const capabilities = JSON.parse(readFileSync("src-tauri/capabilities/default.json", "utf8")) as { permissions: string[] };
  const appearanceCapabilities = JSON.parse(readFileSync("src-tauri/capabilities/appearance.json", "utf8")) as {
    windows: string[];
    permissions: string[];
  };
  const tauriConfig = JSON.parse(readFileSync("src-tauri/tauri.conf.json", "utf8")) as {
    app: { security: { assetProtocol?: { enable: boolean; scope: { allow: string[]; deny?: string[] } } } };
  };

  it.each([
    "core:window:allow-hide",
    "core:window:allow-set-always-on-top",
    "core:window:allow-set-position",
    "core:window:allow-start-dragging",
  ])("grants the runtime operation %s", (permission) => {
    expect(capabilities.permissions).toContain(permission);
  });

  it("isolates the appearance center in its own minimal capability", () => {
    expect(appearanceCapabilities.windows).toEqual(["appearance"]);
    expect(appearanceCapabilities.permissions).toContain("core:event:allow-listen");
    expect(appearanceCapabilities.permissions).toContain("core:event:allow-unlisten");
    expect(appearanceCapabilities.permissions).not.toContain("core:event:allow-emit");
    expect(appearanceCapabilities.permissions).not.toContain("core:event:default");
    expect(appearanceCapabilities.permissions).not.toContain("core:default");
    expect(appearanceCapabilities.permissions).not.toContain("autostart:default");
    expect(appearanceCapabilities.permissions).not.toContain("log:default");
    expect(appearanceCapabilities.permissions).not.toContain("allow-quit-app");
    expect(appearanceCapabilities.permissions).not.toContain("allow-write-settings-file");
    expect(appearanceCapabilities.permissions).not.toContain("allow-quarantine-invalid-settings-file");
    expect(appearanceCapabilities.permissions).toContain("allow-request-character-selection");
    for (const permission of [
      "allow-set-active-character-id",
      "allow-begin-character-activation",
      "allow-commit-character-selection",
      "allow-finalize-character-selection",
      "allow-cancel-character-selection",
    ]) {
      expect(capabilities.permissions).toContain(permission);
      expect(appearanceCapabilities.permissions).not.toContain(permission);
    }
    expect(capabilities.permissions).not.toContain("allow-import-character-package");
    expect(capabilities.permissions).not.toContain("allow-remove-installed-character");
    expect(capabilities.permissions).not.toContain("allow-request-character-selection");
  });

  it("exposes only the installed character subtree through the asset protocol", () => {
    const protocol = tauriConfig.app.security.assetProtocol;
    expect(protocol?.enable).toBe(true);
    expect(protocol?.scope.allow).toEqual(["$APPLOCALDATA/characters/**/*"]);
    expect(protocol?.scope.deny).toContain("$APPLOCALDATA/EBWebView/**/*");
    expect(protocol?.scope.allow).not.toContain("**/*");
  });
});
