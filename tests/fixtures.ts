import type { LoadedCharacter } from "../src/core/character/types";

export function makeCharacter(): LoadedCharacter {
  const idle = { state: "idle" as const, path: "idle", fps: 8, loop: true, priority: 10, frames: ["idle-1.png", "idle-2.png"] };
  return {
    baseUrl: "/characters/test",
    warnings: [],
    manifest: {
      schemaVersion: 1, id: "test", name: "Test", version: "1", author: "Test", license: "Test", defaultScale: 1,
      frameSize: { width: 256, height: 256 }, anchor: { x: 0.5, y: 1 },
      animations: {
        idle,
        click: { path: "click", fps: 10, loop: false, returnTo: "idle", priority: 80, interruptible: false },
        drag: { path: "drag", fps: 1, loop: true, priority: 100 },
      },
    },
    animations: {
      idle,
      click: { state: "click", path: "click", fps: 10, loop: false, returnTo: "idle", priority: 80, interruptible: false, frames: ["click.png"] },
      drag: { state: "drag", path: "drag", fps: 1, loop: true, priority: 100, frames: ["drag.png"] },
    },
  };
}

