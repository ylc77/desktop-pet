import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ invoke: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: mocks.invoke }));

import { DEFAULT_SETTINGS } from "../src/core/settings/settingsSchema";
import { saveSettings, saveSettingsStrict } from "../src/core/settings/settingsStore";

function enableTauriRuntime(): void {
  Object.defineProperty(window, "__TAURI_INTERNALS__", { configurable: true, value: {} });
}

afterEach(() => {
  delete (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__;
  localStorage.clear();
  mocks.invoke.mockReset();
});

describe("settings persistence", () => {
  it("blocks update handoff when the authoritative native write fails", async () => {
    enableTauriRuntime();
    localStorage.setItem("settings", "previous-value");
    mocks.invoke.mockRejectedValueOnce(new Error("native write failed"));

    await expect(saveSettingsStrict({ ...DEFAULT_SETTINGS, scale: 1.5 })).rejects.toThrow("native write failed");
    expect(localStorage.getItem("settings")).toBe("previous-value");
  });

  it("keeps the ordinary best-effort browser fallback outside update handoff", async () => {
    enableTauriRuntime();
    mocks.invoke.mockRejectedValueOnce(new Error("native write failed"));

    await expect(saveSettings({ ...DEFAULT_SETTINGS, scale: 1.5 })).resolves.toBeUndefined();
    expect(JSON.parse(localStorage.getItem("settings") ?? "null").scale).toBe(1.5);
  });
});
