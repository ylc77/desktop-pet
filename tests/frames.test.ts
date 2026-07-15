import { describe, expect, it } from "vitest";
import { getFrameDelay, nextFrameIndex } from "../src/core/animation/framePreloader";

describe("frame playback", () => {
  it("loops at the final frame", () => expect(nextFrameIndex(2, 3, true)).toEqual({ index: 0, completed: false }));
  it("completes a one-shot at the final frame", () => expect(nextFrameIndex(2, 3, false)).toEqual({ index: 2, completed: true }));
  it("clamps FPS", () => expect(getFrameDelay(120)).toBeCloseTo(1000 / 60));
});

