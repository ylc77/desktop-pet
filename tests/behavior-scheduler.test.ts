import { describe, expect, it } from "vitest";
import { BehaviorScheduler, createSeededRandom } from "../src/core/animation/BehaviorScheduler";
import { makeCharacter } from "./fixtures";

function ambientCharacter() {
  const character = makeCharacter();
  character.animations.click!.weight = 5;
  character.animations.click!.minDelayMs = 1_000;
  character.animations.click!.maxDelayMs = 2_000;
  character.animations.drag!.weight = 0;
  character.animations.wave = { state: "wave", path: "wave", fps: 8, loop: false, returnTo: "idle", weight: 5, minDelayMs: 2_000, maxDelayMs: 3_000, frames: ["wave.png"] };
  return character;
}

describe("BehaviorScheduler", () => {
  it("produces the same plans for the same seed", () => {
    const left = new BehaviorScheduler(ambientCharacter(), createSeededRandom(42));
    const right = new BehaviorScheduler(ambientCharacter(), createSeededRandom(42));
    expect([left.plan(0), left.plan(1_000), left.plan(2_000)]).toEqual([right.plan(0), right.plan(1_000), right.plan(2_000)]);
  });

  it("prevents an immediate repeat when another action exists", () => {
    const scheduler = new BehaviorScheduler(ambientCharacter(), () => 0);
    const first = scheduler.plan(0)!;
    scheduler.record(first.state, 0);
    expect(scheduler.plan(10)!.state).not.toBe(first.state);
  });

  it("uses candidate-specific quiet intervals", () => {
    const scheduler = new BehaviorScheduler(ambientCharacter(), () => 0);
    const plan = scheduler.plan(0)!;
    expect(plan.state).toBe("click");
    expect(plan.delayMs).toBe(1_000);
  });

  it("never schedules animations that move the desktop window", () => {
    const character = ambientCharacter();
    character.animations.walk = {
      state: "walk",
      path: "walk",
      fps: 8,
      loop: true,
      weight: 10_000,
      movement: { speed: 60 },
      frames: ["walk.png"],
    };
    character.animations.click!.weight = 1;
    character.animations.wave!.weight = 0;

    expect(new BehaviorScheduler(character, () => 0).plan(0)?.state).toBe("click");
  });

  it("keeps bounded recent history", () => {
    const scheduler = new BehaviorScheduler(ambientCharacter(), () => 0, 2);
    scheduler.record("click", 0); scheduler.record("wave", 1); scheduler.record("click", 2);
    expect(scheduler.history).toEqual(["wave", "click"]);
  });
});
