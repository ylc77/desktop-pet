import { describe, expect, it } from "vitest";
import { appSettingsSchema, DEFAULT_SETTINGS } from "../src/core/settings/settingsSchema";
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
  });
  it("accepts finite off-screen coordinates for the native recovery layer", () => {
    expect(appSettingsSchema.parse({ ...DEFAULT_SETTINGS, position: { x: -100000, y: 100000 } }).position).toEqual({ x: -100000, y: 100000 });
  });
  it.each([0.1, 0.25, 2, 4])("preserves schema-compatible character scale %s", (scale) => {
    expect(appSettingsSchema.parse({ ...DEFAULT_SETTINGS, scale }).scale).toBe(scale);
  });
});
