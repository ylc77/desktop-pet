import { describe, expect, it } from "vitest";
import { DEFAULT_DECODED_FRAME_BUDGET_BYTES, getDecodedFrameCachePlan, keepLoadedFrames } from "../src/core/character/CharacterLoader";
import { makeCharacter } from "./fixtures";

describe("character frame recovery", () => {
  it("removes broken optional frames without breaking the character", () => {
    const character = makeCharacter();
    const recovered = keepLoadedFrames(character, new Set(["idle-1.png", "idle-2.png", "drag.png"]));
    expect(recovered.animations.click).toBeUndefined();
    expect(recovered.animations.idle.frames).toHaveLength(2);
  });

  it("rejects a character when every idle frame is broken", () => {
    expect(() => keepLoadedFrames(makeCharacter(), new Set(["click.png", "drag.png"]))).toThrow(/idle/);
  });

  it("limits retained decoded pixels for ordinary and maximum legal canvases", () => {
    const ordinary = getDecodedFrameCachePlan({ width: 512, height: 512 });
    expect(ordinary.maximumEntries).toBe(64);
    expect(ordinary.estimatedRetainedBytes).toBeLessThanOrEqual(DEFAULT_DECODED_FRAME_BUDGET_BYTES);
    const maximum = getDecodedFrameCachePlan({ width: 4096, height: 4096 });
    expect(maximum).toMatchObject({ maximumEntries: 1, concurrency: 1, estimatedRetainedBytes: DEFAULT_DECODED_FRAME_BUDGET_BYTES });
  });

  it("honors a smaller caller entry cap without exceeding the byte budget", () => {
    expect(getDecodedFrameCachePlan({ width: 256, height: 256 }, 12)).toMatchObject({ maximumEntries: 12, concurrency: 6 });
  });
});
