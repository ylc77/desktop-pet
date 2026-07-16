import { describe, expect, it } from "vitest";
import { DecodedFrameCache, type DecodedFrameResource } from "../src/core/character/DecodedFrameCache";

describe("DecodedFrameCache", () => {
  it("limits decode concurrency", async () => {
    let active = 0; let maximum = 0;
    const decoder = async (source: string): Promise<DecodedFrameResource> => {
      active += 1; maximum = Math.max(maximum, active);
      await Promise.resolve();
      active -= 1;
      return { source, release: () => undefined };
    };
    const cache = new DecodedFrameCache(20, decoder);
    const result = await cache.preload(Array.from({ length: 12 }, (_, index) => `${index}.png`), undefined, 3);
    expect(result.loaded.size).toBe(12);
    expect(maximum).toBeLessThanOrEqual(3);
  });

  it("filters decode failures without discarding valid frames", async () => {
    const cache = new DecodedFrameCache(10, async (source) => {
      if (source.includes("bad")) throw new Error("decode failed");
      return { source, release: () => undefined };
    });
    const result = await cache.preload(["idle.png", "bad.png"]);
    expect([...result.loaded]).toEqual(["idle.png"]);
    expect(result.failed).toEqual(["bad.png"]);
  });

  it("releases evicted and disposed decoded resources", async () => {
    const released: string[] = [];
    const cache = new DecodedFrameCache(2, async (source) => ({ source, release: () => released.push(source) }));
    await cache.preload(["1.png", "2.png", "3.png"], undefined, 1);
    expect(released).toContain("1.png");
    cache.dispose();
    expect(released).toEqual(expect.arrayContaining(["1.png", "2.png", "3.png"]));
    expect(cache.size).toBe(0);
  });

  it("aborts a reload without committing late resources", async () => {
    const controller = new AbortController();
    const released: string[] = [];
    const cache = new DecodedFrameCache(5, async (source, signal) => {
      controller.abort();
      if (signal?.aborted) { const error = new Error("aborted"); error.name = "AbortError"; throw error; }
      return { source, release: () => released.push(source) };
    });
    await expect(cache.preload(["idle.png"], controller.signal)).rejects.toMatchObject({ name: "AbortError" });
    expect(cache.size).toBe(0);
  });

  it("releases the previous generation across repeated character reloads", async () => {
    const active = new Set<string>();
    let previous: DecodedFrameCache | null = null;
    for (let generation = 0; generation < 8; generation += 1) {
      const cache = new DecodedFrameCache(4, async (source) => {
        const key = `${generation}:${source}`;
        active.add(key);
        return { source, release: () => active.delete(key) };
      });
      await cache.preload(["idle-1.png", "idle-2.png", "click.png"]);
      previous?.dispose();
      previous = cache;
      expect(active.size).toBe(3);
    }
    previous?.dispose();
    expect(active.size).toBe(0);
  });
});
