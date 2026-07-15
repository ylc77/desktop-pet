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
});
