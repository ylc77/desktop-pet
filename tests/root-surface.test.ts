import { describe, expect, it } from "vitest";
import { resolveRootSurfaceId } from "../src/app/rootSurface";

describe("root surface routing", () => {
  it.each([
    ["main", "main"],
    ["appearance", "appearance"],
    ["settings", "settings"],
  ] as const)("routes the %s window without starting another main app", (label, expected) => {
    expect(resolveRootSurfaceId(label, "")).toBe(expected);
  });

  it("supports explicit browser preview surfaces without affecting Tauri labels", () => {
    expect(resolveRootSurfaceId(null, "?surface=settings&section=about")).toBe("settings");
    expect(resolveRootSurfaceId("main", "?surface=settings")).toBe("main");
  });

  it("fails safely for unknown window labels", () => {
    expect(resolveRootSurfaceId("unexpected", "")).toBe("unknown");
    expect(resolveRootSurfaceId(null, "?surface=unexpected")).toBe("unknown");
  });
});
