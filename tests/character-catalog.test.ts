import { describe, expect, it, vi } from "vitest";
import {
  createInstalledCharacter,
  isSelectionRequestExpired,
  mergeCharacterCatalog,
  nextActivationGeneration,
  prepareCharacterTransaction,
  toLocalAssetUrl,
  type CharacterCatalogEntry,
} from "../src/core/character/CharacterCatalog";

function entry(id: string, source: "bundled" | "local", overrides: Partial<CharacterCatalogEntry> = {}): CharacterCatalogEntry {
  return {
    id,
    source,
    name: id,
    version: "1.0.0",
    author: "作者",
    license: "许可",
    valid: true,
    errors: [],
    ...overrides,
  };
}

describe("character catalog", () => {
  it("treats a selection request as expired at and after its absolute deadline", () => {
    expect(isSelectionRequestExpired({}, 10_000)).toBe(false);
    expect(isSelectionRequestExpired({ expiresAtMs: 10_001 }, 10_000)).toBe(false);
    expect(isSelectionRequestExpired({ expiresAtMs: 10_000 }, 10_000)).toBe(true);
    expect(isSelectionRequestExpired({ expiresAtMs: 9_999 }, 10_000)).toBe(true);
  });

  it("keeps native activation generations monotonic across React remount-style resets", () => {
    const first = nextActivationGeneration(10_000);
    const second = nextActivationGeneration(10_000);
    expect(second).toBeGreaterThan(first);
    expect(first).toBeGreaterThanOrEqual(10_000);
  });

  it("merges bundled and local entries while making ID collisions unselectable", () => {
    const merged = mergeCharacterCatalog(
      [entry("shared", "bundled"), entry("official", "bundled")],
      [entry("shared", "local"), entry("personal", "local")],
    );

    expect(merged).toHaveLength(4);
    expect(merged.slice(0, 2).every((item) => item.source === "bundled")).toBe(true);
    expect(merged.find((item) => item.id === "shared" && item.source === "local")).toMatchObject({
      valid: false,
      errors: [expect.stringContaining("内置角色冲突")],
    });
    expect(merged.find((item) => item.id === "personal")).toMatchObject({ valid: true, source: "local" });
  });

  it("converts native local paths without exposing them as browser file URLs", () => {
    const converter = vi.fn((path: string) => `asset://localhost/${encodeURIComponent(path)}`);
    const nativePath = "C:\\Users\\测试 用户\\角色\\preview.png";
    expect(toLocalAssetUrl(nativePath, converter)).toBe(`asset://localhost/${encodeURIComponent(nativePath)}`);
    expect(converter).toHaveBeenCalledWith(nativePath);
    expect(toLocalAssetUrl("", converter)).toBeUndefined();
  });

  it("converts every installed frame path, adds a reload cache key, and keeps schema version 1", () => {
    const converter = vi.fn((path: string) => `asset:${path}`);
    const loaded = createInstalledCharacter({ id: "personal", source: "local" }, {
      manifest: {
        schemaVersion: 1,
        id: "personal",
        name: "我的角色",
        version: "1.0.0",
        author: "用户",
        license: "Private use",
        defaultScale: 1,
        frameSize: { width: 256, height: 256 },
        anchor: { x: 0.5, y: 0.9 },
        animations: { idle: { path: "animations/idle", fps: 8, loop: true } },
      },
      frames: { idle: ["C:\\角色 包\\idle_0001.png", "C:\\角色 包\\idle_0002.png"] },
    }, converter, 7);

    expect(loaded.manifest.schemaVersion).toBe(1);
    expect(loaded.animations.idle.frames).toEqual([
      "asset:C:\\角色 包\\idle_0001.png?qipetRevision=1.0.0%3A7",
      "asset:C:\\角色 包\\idle_0002.png?qipetRevision=1.0.0%3A7",
    ]);
    expect(converter).toHaveBeenCalledTimes(2);
  });

  it("changes a local asset URL when the package revision changes", () => {
    const converter = (path: string) => `asset://localhost/${encodeURIComponent(path)}`;
    const path = "C:\\角色 包\\preview.png";
    expect(toLocalAssetUrl(path, converter, "1.0.0")).not.toBe(toLocalAssetUrl(path, converter, "1.1.0"));
  });

  it("keeps the active value when candidate preparation fails", async () => {
    const active = { id: "active", release: vi.fn() };
    const result = await prepareCharacterTransaction(active, async () => { throw new Error("idle 帧损坏"); });
    expect(result).toEqual({ ok: false, value: active, error: "idle 帧损坏" });
    expect(active.release).not.toHaveBeenCalled();
  });

  it("returns the fully prepared candidate only after preparation succeeds", async () => {
    const active = { id: "active" };
    const candidate = { id: "candidate" };
    await expect(prepareCharacterTransaction(active, async () => candidate)).resolves.toEqual({ ok: true, value: candidate });
  });
});
