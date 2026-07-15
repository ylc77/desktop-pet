import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("Tauri window capabilities", () => {
  const capabilities = JSON.parse(readFileSync("src-tauri/capabilities/default.json", "utf8")) as { permissions: string[] };

  it.each([
    "core:window:allow-hide",
    "core:window:allow-set-always-on-top",
    "core:window:allow-set-position",
    "core:window:allow-start-dragging",
  ])("grants the runtime operation %s", (permission) => {
    expect(capabilities.permissions).toContain(permission);
  });
});
