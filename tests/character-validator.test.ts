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
  it("keeps schema 1 compatible while accepting optional phase, movement, and visual metadata", () => {
    const result = validateManifest({
      ...valid,
      visual: { dropShadow: false, groundShadow: { enabled: true, opacity: 0.15 } },
      animations: {
        idle: valid.animations.idle,
        prepare: { path: "prepare", fps: 8, loop: false },
        click: { path: "click", fps: 10, loop: false, anticipation: "prepare", recovery: "idle", movement: { speed: 40, acceleration: 120, deceleration: 160, direction: "left", reverseTo: "walk_right" } },
        walk_right: { path: "walk_right", fps: 10, loop: true, movement: { speed: 40, direction: "right", reverseTo: "click" } },
      },
    });
    expect(result.valid).toBe(true);
    expect(result.manifest?.schemaVersion).toBe(1);
  });
  it("rejects inverted ambient duration ranges", () => {
    expect(validateManifest({ ...valid, animations: { idle: { ...valid.animations.idle, minDurationMs: 5000, maxDurationMs: 1000 } } }).valid).toBe(false);
  });
});
