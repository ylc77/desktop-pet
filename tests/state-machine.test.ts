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

  it("runs optional anticipation and recovery phases without changing schema version", () => {
    const character = makeCharacter();
    character.animations.prepare = { state: "prepare", path: "prepare", fps: 8, loop: false, frames: ["prepare.png"] };
    character.animations.recover = { state: "recover", path: "recover", fps: 8, loop: false, frames: ["recover.png"] };
    character.animations.click!.anticipation = "prepare";
    character.animations.click!.recovery = "recover";
    const machine = new AnimationStateMachine(character, () => 10);
    expect(machine.transition("click", "test")).toBe(true);
    expect(machine.snapshot.state).toBe("prepare");
    expect(machine.queue).toEqual(["click", "recover", "idle"]);
    machine.complete(); expect(machine.snapshot.state).toBe("click");
    machine.complete(); expect(machine.snapshot.state).toBe("recover");
    machine.complete(); expect(machine.snapshot.state).toBe("idle");
    expect(character.manifest.schemaVersion).toBe(1);
  });

  it("records rejected and forced transitions in a bounded diagnostic history", () => {
    const machine = new AnimationStateMachine(makeCharacter());
    machine.transition("click", "click");
    expect(machine.transition("idle", "too-low")).toBe(false);
    machine.transition("drag", "forced-drag", true);
    expect(machine.recentTransitions.at(-2)).toMatchObject({ requested: "idle", accepted: false, rejectedBy: "non-interruptible" });
    expect(machine.recentTransitions.at(-1)).toMatchObject({ requested: "drag", accepted: true, forced: true });
    for (let index = 0; index < 40; index += 1) machine.transition("idle", `forced-${index}`, true);
    expect(machine.recentTransitions.length).toBeLessThanOrEqual(24);
  });

  it("exits a looping action through its configured recovery", () => {
    const character = makeCharacter();
    character.animations.recover = { state: "recover", path: "recover", fps: 8, loop: false, frames: ["recover.png"] };
    character.animations.drag!.recovery = "recover";
    character.animations.drag!.returnTo = "idle";
    const machine = new AnimationStateMachine(character);
    machine.transition("drag", "ambient", true);
    machine.exitCurrent("loop-boundary");
    expect(machine.snapshot.state).toBe("recover");
    expect(machine.queue).toEqual(["idle"]);
  });
});
