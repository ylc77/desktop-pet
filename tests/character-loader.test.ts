import { describe, expect, it } from "vitest";
import { keepLoadedFrames } from "../src/core/character/CharacterLoader";
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
});
