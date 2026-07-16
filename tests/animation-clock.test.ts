import { describe, expect, it } from "vitest";
import { advanceAnimationClock, createAnimationClock } from "../src/core/animation/animationClock";

function simulate(refreshRate: number, durationMs: number) {
  let state = createAnimationClock();
  let previous = 0;
  const samples = Math.round(refreshRate * durationMs / 1000);
  for (let index = 1; index <= samples; index += 1) {
    const now = index * durationMs / samples;
    state = advanceAnimationClock(state, now - previous, { fps: 8, frameCount: 7, loop: true });
    previous = now;
  }
  return state;
}

describe("elapsed animation clock", () => {
  it("keeps animation speed stable at 60, 120, and 144 Hz", () => {
    const indices = [60, 120, 144].map((rate) => simulate(rate, 1_000).frameIndex);
    expect(indices).toEqual([1, 1, 1]);
  });

  it("caps recovery work after a long stall", () => {
    const next = advanceAnimationClock(createAnimationClock(), 2_000, { fps: 60, frameCount: 20, loop: true, maxCatchUpMs: 250, maxFrameAdvance: 4 });
    expect(next.capped).toBe(true);
    expect(next.advancedFrames).toBe(4);
    expect(next.droppedFrames).toBeGreaterThan(0);
  });

  it("loops without holding the final frame for an extra interval", () => {
    const next = advanceAnimationClock({ ...createAnimationClock(), frameIndex: 2 }, 100, { fps: 10, frameCount: 3, loop: true });
    expect(next.frameIndex).toBe(0);
    expect(next.wrapped).toBe(true);
  });

  it("holds the last one-shot frame before completing exactly once", () => {
    const atLast = advanceAnimationClock(createAnimationClock(), 200, { fps: 10, frameCount: 3, loop: false });
    expect(atLast).toMatchObject({ frameIndex: 2, completed: false });
    const completed = advanceAnimationClock(atLast, 100, { fps: 10, frameCount: 3, loop: false });
    expect(completed.completed).toBe(true);
    expect(advanceAnimationClock(completed, 500, { fps: 10, frameCount: 3, loop: false }).advancedFrames).toBe(0);
  });

  it("does not accumulate hidden time when resume resets the timestamp baseline", () => {
    const beforeHide = advanceAnimationClock(createAnimationClock(), 100, { fps: 10, frameCount: 4, loop: true });
    const afterResume = advanceAnimationClock(beforeHide, 0, { fps: 10, frameCount: 4, loop: true });
    expect(afterResume.frameIndex).toBe(beforeHide.frameIndex);
    expect(afterResume.advancedFrames).toBe(0);
  });
});
