import { describe, expect, it } from "vitest";
import { normalizePetInteractionRegion, samePetInteractionRegion } from "../src/core/window/petInteractionRegion";

describe("pet interaction region", () => {
  it("normalizes and pads a visible hitbox", () => {
    expect(normalizePetInteractionRegion(
      { left: 100, top: 50, right: 300, bottom: 350 },
      { width: 400, height: 400 },
      8,
    )).toEqual({ x: 0.23, y: 0.105, width: 0.54, height: 0.79 });
  });

  it("clips a transformed hitbox to the transparent window", () => {
    expect(normalizePetInteractionRegion(
      { left: -40, top: 20, right: 440, bottom: 500 },
      { width: 400, height: 400 },
      8,
    )).toEqual({ x: 0, y: 0.03, width: 1, height: 0.97 });
  });

  it("rejects empty or invalid geometry", () => {
    expect(normalizePetInteractionRegion(
      { left: 20, top: 20, right: 20, bottom: 100 },
      { width: 400, height: 400 },
    )).toBeNull();
    expect(normalizePetInteractionRegion(
      { left: 20, top: 20, right: 100, bottom: 100 },
      { width: Number.NaN, height: 400 },
    )).toBeNull();
  });

  it("suppresses insignificant republishing jitter", () => {
    expect(samePetInteractionRegion(
      { x: 0.2, y: 0.1, width: 0.6, height: 0.8 },
      { x: 0.20001, y: 0.10001, width: 0.59999, height: 0.80001 },
    )).toBe(true);
    expect(samePetInteractionRegion(null, null)).toBe(true);
    expect(samePetInteractionRegion(null, { x: 0, y: 0, width: 1, height: 1 })).toBe(false);
  });
});
