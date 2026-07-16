import { describe, expect, it } from "vitest";
import { appSettingsSchema, DEFAULT_SETTINGS, resetSettingsPreservingCharacter } from "../src/core/settings/settingsSchema";
import { parseSettings } from "../src/core/settings/settingsStore";

describe("settings schema", () => {
  it("accepts defaults", () => expect(appSettingsSchema.parse(DEFAULT_SETTINGS)).toEqual(DEFAULT_SETTINGS));
  it("rejects an invisible opacity", () => expect(() => appSettingsSchema.parse({ ...DEFAULT_SETTINGS, opacity: 0 })).toThrow());
  it("rejects an excessive scale", () => expect(() => appSettingsSchema.parse({ ...DEFAULT_SETTINGS, scale: 9 })).toThrow());
  it("recovers corrupted persisted settings to defaults", () => {
    const result = parseSettings({ scale: "broken", characterId: 42 });
    expect(result.recovered).toBe(true);
    expect(result.settings).toEqual(DEFAULT_SETTINGS);
  });
  it("fills missing settings fields from defaults", () => {
    const result = parseSettings({ position: { x: 999999, y: -999999 }, scale: 1 });
    expect(result.recovered).toBe(false);
    expect(result.settings.position).toEqual({ x: 999999, y: -999999 });
    expect(result.settings.opacity).toBe(DEFAULT_SETTINGS.opacity);
    expect(result.settings.automaticUpdateChecks).toBe(true);
    expect(result.settings.updateLastCheckAt).toBeNull();
    expect(result.settings.updateLastFailedVersion).toBeNull();
  });
  it("round-trips updater preferences", () => {
    const settings = appSettingsSchema.parse({
      ...DEFAULT_SETTINGS,
      automaticUpdateChecks: false,
      updateLastCheckAt: "2026-07-16T00:00:00Z",
      updateSkippedVersion: "0.2.0-beta.1",
      updateLastFailureCategory: "timeout",
      updateLastFailedVersion: "0.2.0-beta.1",
    });
    expect(settings).toMatchObject({ automaticUpdateChecks: false, updateSkippedVersion: "0.2.0-beta.1", updateLastFailureCategory: "timeout", updateLastFailedVersion: "0.2.0-beta.1" });
  });
  it("reset changes only window, animation/behavior, and updater preferences", () => {
    const reset = resetSettingsPreservingCharacter({
      ...DEFAULT_SETTINGS,
      characterId: "personal-pet",
      skinId: "blue",
      scale: 2,
      opacity: 0.55,
      autostart: true,
      volume: 0.25,
      automaticUpdateChecks: false,
      updateSkippedVersion: "0.2.0-beta.1",
      pendingUpdateVersion: "0.2.0-beta.1",
      lastConfirmedUpdateVersion: "0.1.0",
    });
    expect(reset.characterId).toBe("personal-pet");
    expect(reset.skinId).toBe("blue");
    expect(reset.scale).toBe(DEFAULT_SETTINGS.scale);
    expect(reset.automaticUpdateChecks).toBe(true);
    expect(reset.updateSkippedVersion).toBeNull();
    expect(reset.opacity).toBe(0.55);
    expect(reset.autostart).toBe(true);
    expect(reset.volume).toBe(0.25);
    expect(reset.pendingUpdateVersion).toBe("0.2.0-beta.1");
    expect(reset.lastConfirmedUpdateVersion).toBe("0.1.0");
  });
  it("accepts finite off-screen coordinates for the native recovery layer", () => {
    expect(appSettingsSchema.parse({ ...DEFAULT_SETTINGS, position: { x: -100000, y: 100000 } }).position).toEqual({ x: -100000, y: 100000 });
  });
  it.each([0.1, 0.25, 2, 4])("preserves schema-compatible character scale %s", (scale) => {
    expect(appSettingsSchema.parse({ ...DEFAULT_SETTINGS, scale }).scale).toBe(scale);
  });
});
