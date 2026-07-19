import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const root = resolve(import.meta.dirname, "..");
const characterRoot = resolve(root, "public/characters/qijiang-xiaoyou");
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
  it("registers the approved schema v1 Idle character as a bundled entry", () => {
    const manifest = JSON.parse(readFileSync(resolve(characterRoot, "manifest.json"), "utf8"));
    const index = JSON.parse(readFileSync(resolve(root, "public/characters/index.json"), "utf8"));
    const entry = index.characters.find((candidate: { id: string }) => candidate.id === "qijiang-xiaoyou");

    expect(manifest).toMatchObject({
      schemaVersion: 1,
      id: "qijiang-xiaoyou",
      name: "小幽",
      version: "0.1.0",
      author: "七酱",
      frameSize: { width: 1024, height: 1024 },
      anchor: { x: 0.5, y: 0.900391 },
    });
    expect(manifest.license).not.toMatch(/Private local|本机测试|待用户确认/i);
    expect(manifest.animations).toEqual({
      idle: {
        path: "animations/idle",
        fps: 6,
        loop: true,
        priority: 10,
        weight: 0,
        flipXAllowed: false,
      },
    });
    expect(entry).toMatchObject({
      id: "qijiang-xiaoyou",
      name: "小幽",
      version: "0.1.0",
      manifest: "/characters/qijiang-xiaoyou/manifest.json",
    });
  });

  it("ships exactly the eight visually approved RGBA frames", () => {
    const idleDirectory = resolve(characterRoot, "animations/idle");
    const frames = readdirSync(idleDirectory).sort();
    expect(frames).toEqual(Array.from({ length: 8 }, (_, index) => `idle_${String(index + 1).padStart(4, "0")}.png`));

    const hashes = frames.map((name) => {
      const bytes = readFileSync(resolve(idleDirectory, name));
      expect(bytes.readUInt32BE(16)).toBe(1024);
      expect(bytes.readUInt32BE(20)).toBe(1024);
      expect(bytes[25]).toBe(6);
      return createHash("sha256").update(bytes).digest("hex").toUpperCase();
    });
    expect(hashes).toEqual(expectedIdleHashes);
  });

  it("keeps display assets and public metadata complete and path-safe", () => {
    expect(existsSync(resolve(characterRoot, "preview.png"))).toBe(true);
    expect(existsSync(resolve(characterRoot, "icon.png"))).toBe(true);

    const source = readFileSync(resolve(characterRoot, "metadata/source.md"), "utf8");
    const license = readFileSync(resolve(characterRoot, "metadata/license.md"), "utf8");
    expect(source).toContain("正式内置角色");
    expect(license).toContain("随七酱桌宠官方程序");
    expect(`${source}\n${license}`).not.toMatch(/(?:[A-Za-z]:[\\/]|\\\\)[^\r\n]*/);
  });
});
