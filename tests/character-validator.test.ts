import { describe, expect, it } from "vitest";
import { validateManifest } from "../src/core/character/CharacterValidator";

const valid = {
  schemaVersion: 1, id: "sample", name: "Sample", version: "1.0.0", author: "Dev", license: "Private",
  defaultScale: 1, frameSize: { width: 512, height: 512 }, anchor: { x: 0.5, y: 1 },
  animations: { idle: { path: "animations/idle", fps: 8, loop: true } },
};

describe("validateManifest", () => {
  it("accepts a minimal valid character manifest", () => expect(validateManifest(valid).valid).toBe(true));
  it("accepts the reserved underscore-prefixed placeholder id", () => expect(validateManifest({ ...valid, id: "_placeholder" }).valid).toBe(true));
  it("rejects a path that escapes the character directory", () => {
    const result = validateManifest({ ...valid, animations: { idle: { path: "../secret", fps: 8, loop: true } } });
    expect(result.valid).toBe(false);
    expect(result.errors.join(" ")).toContain("路径");
  });
  it("rejects unreasonable FPS", () => {
    const result = validateManifest({ ...valid, animations: { idle: { path: "idle", fps: 120, loop: true } } });
    expect(result.valid).toBe(false);
  });
  it("accepts resource-defined animation names", () => {
    const result = validateManifest({ ...valid, animations: { ...valid.animations, walk_left: { path: "animations/walk_left", fps: 12, loop: true } } });
    expect(result.valid).toBe(true);
  });
  it("rejects inverted random delay ranges", () => {
    const result = validateManifest({ ...valid, animations: { idle: { path: "idle", fps: 8, loop: true, minDelayMs: 5000, maxDelayMs: 1000 } } });
    expect(result.valid).toBe(false);
  });
  it("rejects hitboxes outside the frame", () => {
    expect(validateManifest({ ...valid, hitbox: { x: 0.8, y: 0, width: 0.4, height: 1 } }).valid).toBe(false);
  });
  it("rejects a manifest without idle", () => {
    expect(validateManifest({ ...valid, animations: { click: { path: "animations/click", fps: 8, loop: false } } }).valid).toBe(false);
  });
});
