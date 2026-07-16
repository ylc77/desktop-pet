import { describe, expect, it } from "vitest";
import { ClickArbiter, DOUBLE_CLICK_WINDOW_MS, exceedsDragThreshold } from "../src/core/animation/interactionArbiter";
import { stepMotion, type MotionState } from "../src/core/animation/motionModel";
import { anchorLayout, mirroredHitbox } from "../src/core/animation/renderGeometry";

describe("interaction arbitration", () => {
  it("delays one click but turns two releases into only a double click", () => {
    const arbiter = new ClickArbiter();
    expect(arbiter.release(100)).toBe("pending-click");
    expect(arbiter.release(100 + DOUBLE_CLICK_WINDOW_MS - 1)).toBe("double-click");
    expect(arbiter.consumePending()).toBe(false);
  });

  it("recognizes the drag threshold and cancellation removes pending click", () => {
    const arbiter = new ClickArbiter();
    arbiter.release(100);
    expect(exceedsDragThreshold({ x: 10, y: 10 }, { x: 16, y: 10 })).toBe(true);
    arbiter.cancel();
    expect(arbiter.consumePending()).toBe(false);
  });
});

describe("weighted window motion", () => {
  const config = { speed: 60, acceleration: 120, deceleration: 180, edgePadding: 20 };
  const bounds = { minimum: 0, maximum: 300 };

  it("accelerates instead of jumping to maximum speed", () => {
    const next = stepMotion({ position: 100, velocity: 0, direction: 1 }, 16, bounds, config);
    expect(next.velocity).toBeGreaterThan(0);
    expect(next.velocity).toBeLessThan(config.speed);
  });

  it("brakes and stays inside the work area", () => {
    let state: MotionState = { position: 270, velocity: 50, direction: 1 };
    for (let index = 0; index < 30; index += 1) state = stepMotion(state, 16, bounds, config);
    expect(state.position).toBeLessThanOrEqual(280);
    expect(state.position).toBeGreaterThanOrEqual(20);
  });

  it("eventually reverses after braking instead of stopping forever near an edge", () => {
    let state: MotionState = { position: 220, velocity: 50, direction: 1 };
    let reversed = false;
    for (let index = 0; index < 120 && !reversed; index += 1) {
      const next = stepMotion(state, 16, bounds, config);
      reversed = next.reversed;
      state = next;
    }
    expect(reversed).toBe(true);
    expect(state.direction).toBe(-1);
    expect(state.position).toBe(280);
  });

  it("is approximately refresh-rate independent", () => {
    const run = (hz: number) => {
      let state: MotionState = { position: 100, velocity: 0, direction: 1 };
      for (let index = 0; index < hz; index += 1) state = stepMotion(state, 1000 / hz, bounds, config);
      return state.position;
    };
    expect(Math.max(run(60), run(120), run(144)) - Math.min(run(60), run(120), run(144))).toBeLessThan(1);
  });

  it("stays stable when the available work area is smaller than the requested padding", () => {
    const next = stepMotion({ position: 20, velocity: 50, direction: 1 }, 16, { minimum: 10, maximum: 10 }, config);
    expect(next).toEqual({ position: 10, velocity: 0, direction: 1, reversed: false });
  });
});

describe("anchor geometry", () => {
  it("mirrors an asymmetric hitbox", () => expect(mirroredHitbox({ x: 0.1, y: 0.2, width: 0.3, height: 0.4 }, true).x).toBeCloseTo(0.6));
  it("maps the declared anchor to the ground origin", () => expect(anchorLayout({ x: 0.25, y: 0.8 }).transform).toBe("translate(-25%, 20%)"));
});
