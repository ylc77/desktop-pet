import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import sharp from "sharp";
import { describe, expect, it } from "vitest";

const root = resolve(import.meta.dirname, "..");
const characterRoot = resolve(root, "public/characters/qijiang-xiaoyou");
const expectedFrameCounts = {
  idle: 8,
  idle_look: 8,
  idle_smile: 8,
  idle_magic: 12,
  walk_left: 8,
  walk_right: 8,
  sleep: 6,
  sleep_enter: 8,
  sleep_wake: 8,
  hover: 6,
  click: 8,
  double_click: 12,
  drag: 4,
  land: 6,
} as const;
const expectedIdleHashes = [
  "852E1D0F312A81156A13D7192369C205750F5010E1A498F9E8A19D44F7291E20",
  "824E42D60485697E3286804E481F9A13ACE39B59006029BD6BABC34133871CDE",
  "C988E5E44E25B19DB9055C9A5A41460B019BB77730EBD4A444C4752FF2EDD43B",
  "BBF767D2F32B3864FD08CAB37B115B492827304326ABE8F8554F511B0E54F550",
  "852E1D0F312A81156A13D7192369C205750F5010E1A498F9E8A19D44F7291E20",
  "CEEC8F6B9B5E8B44412956187C45A31CEC68D262A27A05C65CB56A59223697BB",
  "1C374A936B100B87B271C0AA4BD638C52763B19C0CF65B43B7E69EBAD9581D60",
  "F8C01178CFA64813106D7FE6E75049CF4795B15848492DD265D5EA5B6350C862",
];

describe("bundled Xiaoyou character", () => {
  it("registers the complete schema v1 character without changing the protocol", () => {
    const manifest = JSON.parse(readFileSync(resolve(characterRoot, "manifest.json"), "utf8"));
    const index = JSON.parse(readFileSync(resolve(root, "public/characters/index.json"), "utf8"));
    const entry = index.characters.find((candidate: { id: string }) => candidate.id === "qijiang-xiaoyou");

    expect(manifest).toMatchObject({
      schemaVersion: 1,
      id: "qijiang-xiaoyou",
      name: "小幽",
      version: "0.4.0",
      author: "七酱",
      frameSize: { width: 1024, height: 1024 },
      anchor: { x: 0.5, y: 0.900391 },
      interactions: {
        click: "click",
        doubleClick: "double_click",
        hover: "hover",
        drag: "drag",
        land: "land",
        cooldownMs: 350,
      },
    });
    expect(Object.keys(manifest.animations)).toEqual(Object.keys(expectedFrameCounts));
    expect(manifest.animations.sleep).toMatchObject({ anticipation: "sleep_enter", recovery: "sleep_wake" });
    expect(manifest.animations.walk_left.movement).toMatchObject({ direction: "left", reverseTo: "walk_right" });
    expect(manifest.animations.walk_right.movement).toMatchObject({ direction: "right", reverseTo: "walk_left" });
    expect(manifest.animations.walk_left.weight).toBe(0);
    expect(manifest.animations.walk_right.weight).toBe(0);
    expect(manifest.animations.walk_left.fps).toBe(8);
    expect(manifest.animations.walk_right.fps).toBe(8);
    expect(manifest.animations.sleep.fps).toBe(2);
    expect(manifest.animations.sleep_enter.fps).toBe(4);
    expect(manifest.animations.sleep_wake.fps).toBe(4);
    expect(manifest.animations.idle_look).toMatchObject({ fps: 6, loop: false, returnTo: "idle", priority: 20, weight: 45, minDelayMs: 20000, maxDelayMs: 45000 });
    expect(manifest.animations.idle_smile).toMatchObject({ fps: 6, loop: false, returnTo: "idle", priority: 20, weight: 35, minDelayMs: 25000, maxDelayMs: 50000 });
    expect(manifest.animations.idle_magic).toMatchObject({ fps: 8, loop: false, returnTo: "idle", priority: 20, weight: 20, minDelayMs: 45000, maxDelayMs: 90000 });
    expect(manifest.animations.sleep).toMatchObject({ weight: 5, minDelayMs: 90000, maxDelayMs: 150000 });
    expect(manifest.animations.walk_left.scale).toBe(1.08);
    expect(manifest.animations.walk_right.scale).toBe(1.08);
    expect(manifest.license).not.toMatch(/Private local|本机测试|待用户确认/i);
    expect(entry).toMatchObject({
      id: "qijiang-xiaoyou",
      name: "小幽",
      version: "0.4.0",
      manifest: "/characters/qijiang-xiaoyou/manifest.json",
    });
  });

  it("ships exactly 110 consecutive 1024px RGBA frames", () => {
    let total = 0;
    for (const [action, count] of Object.entries(expectedFrameCounts)) {
      const directory = resolve(characterRoot, "animations", action);
      const frames = readdirSync(directory).sort();
      expect(frames).toEqual(Array.from({ length: count }, (_, index) => `${action}_${String(index + 1).padStart(4, "0")}.png`));
      total += frames.length;

      for (const name of frames) {
        const bytes = readFileSync(resolve(directory, name));
        expect(bytes.readUInt32BE(16)).toBe(1024);
        expect(bytes.readUInt32BE(20)).toBe(1024);
        expect(bytes[24]).toBe(8);
        expect(bytes[25]).toBe(6);
      }
    }
    expect(total).toBe(110);
  });

  it("keeps the approved idle magic endpoints, symmetric arm transition, and stable blink", async () => {
    const directory = resolve(characterRoot, "animations/idle_magic");
    const idle = readFileSync(resolve(characterRoot, "animations/idle/idle_0001.png"));
    expect(Buffer.compare(readFileSync(resolve(directory, "idle_magic_0001.png")), idle)).toBe(0);
    expect(Buffer.compare(readFileSync(resolve(directory, "idle_magic_0012.png")), idle)).toBe(0);
    expect(Buffer.compare(
      readFileSync(resolve(directory, "idle_magic_0002.png")),
      readFileSync(resolve(directory, "idle_magic_0010.png")),
    )).toBe(0);

    const face = { left: 390, top: 220, width: 240, height: 145 };
    const readFace = (id: string) => sharp(resolve(directory, `idle_magic_${id}.png`))
      .extract(face)
      .ensureAlpha()
      .raw()
      .toBuffer();
    const baseline = await readFace("0003");
    for (const id of ["0004", "0005", "0008", "0009"]) {
      expect(Buffer.compare(await readFace(id), baseline)).toBe(0);
    }
    const closed6 = await readFace("0006");
    const closed7 = await readFace("0007");
    expect(Buffer.compare(closed6, closed7)).toBe(0);
    expect(Buffer.compare(closed6, baseline)).not.toBe(0);
  });

  it("keeps ambient expression edits inside the face while preserving the approved silhouette", async () => {
    const idle = await sharp(resolve(characterRoot, "animations/idle/idle_0001.png")).ensureAlpha().raw().toBuffer({ resolveWithObject: true });

    for (const action of ["idle_look", "idle_smile"] as const) {
      const directory = resolve(characterRoot, "animations", action);
      const frames = readdirSync(directory).sort();
      const candidates = await Promise.all(frames.map((name) =>
        sharp(resolve(directory, name)).ensureAlpha().raw().toBuffer({ resolveWithObject: true }),
      ));

      for (const [index, candidate] of candidates.entries()) {
        expect(candidate.info).toMatchObject({ width: 1024, height: 1024, channels: 4 });
        let changedPixels = 0;
        let alphaMismatchPixels = 0;
        let changesOutsideFace = 0;

        for (let pixel = 0; pixel < 1024 * 1024; pixel += 1) {
          const offset = pixel * 4;
          if (candidate.data[offset + 3] !== idle.data[offset + 3]) alphaMismatchPixels += 1;
          if (
            candidate.data[offset] === idle.data[offset]
            && candidate.data[offset + 1] === idle.data[offset + 1]
            && candidate.data[offset + 2] === idle.data[offset + 2]
          ) continue;
          changedPixels += 1;
          const x = pixel % 1024;
          const y = Math.floor(pixel / 1024);
          if (x < 345 || x >= 672 || y < 220 || y >= 401) changesOutsideFace += 1;
        }

        expect(alphaMismatchPixels).toBe(0);
        expect(changesOutsideFace).toBe(0);
        if (index === 0 || index === frames.length - 1) expect(changedPixels).toBe(0);
        else expect(changedPixels).toBeGreaterThan(0);
      }
    }
  });

  it("preserves all eight approved Idle frames byte-for-byte", () => {
    const idleDirectory = resolve(characterRoot, "animations/idle");
    const hashes = readdirSync(idleDirectory).sort().map((name) =>
      createHash("sha256").update(readFileSync(resolve(idleDirectory, name))).digest("hex").toUpperCase(),
    );
    expect(hashes).toEqual(expectedIdleHashes);
  });

  it("derives every right-facing ice glide frame by exact horizontal mirroring", async () => {
    const comparisons = await Promise.all(Array.from({ length: expectedFrameCounts.walk_left }, async (_, offset) => {
      const index = offset + 1;
      const sequence = String(index).padStart(4, "0");
      const leftPath = resolve(characterRoot, "animations/walk_left", `walk_left_${sequence}.png`);
      const rightPath = resolve(characterRoot, "animations/walk_right", `walk_right_${sequence}.png`);
      const [mirrored, right] = await Promise.all([
        sharp(leftPath).flop().raw().toBuffer({ resolveWithObject: true }),
        sharp(rightPath).raw().toBuffer({ resolveWithObject: true }),
      ]);

      return {
        dimensionsMatch: right.info.width === mirrored.info.width
          && right.info.height === mirrored.info.height
          && right.info.channels === mirrored.info.channels,
        pixelComparison: Buffer.compare(mirrored.data, right.data),
      };
    }));

    for (const comparison of comparisons) {
      expect(comparison.dimensionsMatch).toBe(true);
      expect(comparison.pixelComparison).toBe(0);
    }
  });

  it("keeps repaired interaction and sleep transitions on exact approved endpoints", () => {
    const animations = resolve(characterRoot, "animations");
    const pairs = [
      ["click/click_0001.png", "idle/idle_0001.png"],
      ["click/click_0008.png", "idle/idle_0001.png"],
      ["hover/hover_0001.png", "idle/idle_0001.png"],
      ["hover/hover_0006.png", "idle/idle_0001.png"],
      ["land/land_0001.png", "drag/drag_0004.png"],
      ["land/land_0006.png", "idle/idle_0001.png"],
      ["sleep_enter/sleep_enter_0001.png", "idle/idle_0001.png"],
      ["sleep_enter/sleep_enter_0008.png", "sleep/sleep_0001.png"],
      ["sleep_wake/sleep_wake_0001.png", "sleep/sleep_0006.png"],
      ["sleep_wake/sleep_wake_0008.png", "idle/idle_0001.png"],
    ] as const;

    for (const [actual, expected] of pairs) {
      expect(Buffer.compare(readFileSync(resolve(animations, actual)), readFileSync(resolve(animations, expected)))).toBe(0);
    }
  });

  it("keeps the sleep loop fully visible with a stable ground line", async () => {
    const directory = resolve(characterRoot, "animations/sleep");
    const bounds = [];
    const images = await Promise.all(readdirSync(directory).sort().map((name) =>
      sharp(resolve(directory, name)).ensureAlpha().raw().toBuffer({ resolveWithObject: true }),
    ));

    for (const image of images) {
      let minX = image.info.width;
      let minY = image.info.height;
      let maxX = -1;
      let maxY = -1;

      for (let y = 0; y < image.info.height; y += 1) {
        for (let x = 0; x < image.info.width; x += 1) {
          if (image.data[(y * image.info.width + x) * image.info.channels + 3] === 0) continue;
          minX = Math.min(minX, x);
          minY = Math.min(minY, y);
          maxX = Math.max(maxX, x);
          maxY = Math.max(maxY, y);
        }
      }

      bounds.push({ minX, minY, maxX, maxY });
    }

    expect(bounds.every(({ minX, minY, maxX, maxY }) => minX > 0 && minY > 0 && maxX < 1023 && maxY < 1023)).toBe(true);
    expect(new Set(bounds.map(({ maxY }) => maxY))).toEqual(new Set([856]));
    const widths = bounds.map(({ minX, maxX }) => maxX - minX + 1);
    expect(Math.max(...widths) - Math.min(...widths)).toBeLessThanOrEqual(2);
  });

  it("keeps display assets and public metadata complete and path-safe", () => {
    expect(existsSync(resolve(characterRoot, "preview.png"))).toBe(true);
    expect(existsSync(resolve(characterRoot, "icon.png"))).toBe(true);
    expect(existsSync(resolve(root, "scripts/assets/qijiang-xiaoyou/directional-float-left-master.png"))).toBe(true);

    const source = readFileSync(resolve(characterRoot, "metadata/source.md"), "utf8");
    const license = readFileSync(resolve(characterRoot, "metadata/license.md"), "utf8");
    expect(source).toContain("14 个动作、110 帧");
    expect(source).toContain("idle_magic");
    expect(source).toContain("xiaoyou_ambient_look_smile_v1.zip");
    expect(source).toContain("冰晶漂浮");
    expect(source).toContain("确定性合成");
    expect(source).toContain("directional-float-left-master.png");
    expect(license).toContain("随七酱桌宠官方程序");
    expect(`${source}\n${license}`).not.toMatch(/(?:[A-Za-z]:[\\/]|\\\\)[^\r\n]*/);
  });
});
