import { describe, expect, it, vi } from "vitest";
import { AnimationStateMachine } from "../src/core/animation/AnimationStateMachine";
import { makeCharacter } from "./fixtures";

describe("AnimationStateMachine", () => {
  it("falls back to idle when an animation is missing", () => {
    const machine = new AnimationStateMachine(makeCharacter());
    machine.transition("happy", "test", true);
    expect(machine.snapshot.state).toBe("idle");
    expect(machine.snapshot.reason).toContain("fallback-idle");
  });

  it("protects a non-interruptible animation from lower priority states", () => {
    const machine = new AnimationStateMachine(makeCharacter());
    expect(machine.transition("click", "test")).toBe(true);
    expect(machine.transition("idle", "test")).toBe(false);
    expect(machine.transition("drag", "test")).toBe(false);
    expect(machine.transition("drag", "forced-drag", true)).toBe(true);
  });

  it("blocks lower-priority states until the current animation completes", () => {
    const machine = new AnimationStateMachine(makeCharacter());
    expect(machine.transition("drag", "test")).toBe(true);
    expect(machine.transition("click", "test")).toBe(false);
  });

  it("returns one-shot animations to their configured state", () => {
    const machine = new AnimationStateMachine(makeCharacter());
    machine.transition("click", "test");
    machine.complete();
    expect(machine.snapshot.state).toBe("idle");
  });

  it("chooses weighted ambient states deterministically", () => {
    const character = makeCharacter();
    character.animations.click!.weight = 10;
    const machine = new AnimationStateMachine(character);
    expect(machine.chooseAmbient(vi.fn(() => 0))).toBe("click");
  });
});
