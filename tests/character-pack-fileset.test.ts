import {
  cpSync,
  existsSync,
  linkSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  symlinkSync,
  truncateSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { afterEach, describe, expect, it } from "vitest";

const validator = resolve("scripts/validate-character-pack.mjs");
const packager = resolve("scripts/package-character.ps1");
const sourceCharacter = resolve("public/characters/_placeholder");
const temporaryRoots: string[] = [];
const maximumPackageBytes = 512 * 1024 * 1024;

function createFixture(): { root: string; character: string } {
  const root = mkdtempSync(join(tmpdir(), "qijiang-character-fileset-"));
  temporaryRoots.push(root);
  const character = join(root, "_placeholder");
  cpSync(sourceCharacter, character, { recursive: true });
  return { root, character };
}

function runValidator(root: string) {
  return spawnSync(process.execPath, [validator, "--root", root], { encoding: "utf8" });
}

function addFile(character: string, relative: string, content = "not allowed"): void {
  const target = join(character, ...relative.split("/"));
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, content, "utf8");
}

function readManifest(character: string): Record<string, any> {
  return JSON.parse(readFileSync(join(character, "manifest.json"), "utf8")) as Record<string, any>;
}

function writeManifest(character: string, manifest: Record<string, any>): void {
  writeFileSync(join(character, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
}

function areSymlinksUnavailable(error: unknown): boolean {
  return Boolean(error && typeof error === "object" && "code" in error
    && ["EACCES", "EPERM", "UNKNOWN"].includes(String(error.code)));
}

afterEach(() => {
  for (const root of temporaryRoots.splice(0)) rmSync(root, { recursive: true, force: true });
});

describe("character package declared file set", () => {
  it("accepts generated frames, declared PNG assets, metadata, and declared skin metadata", () => {
    const fixture = createFixture();
    const result = runValidator(fixture.root);
    expect(result.status, `${result.stdout}\n${result.stderr}`).toBe(0);
  });

  it.each([
    "payload/runner.exe",
    "payload/helper.dll",
    "payload/install.ps1",
    "payload/preview.html",
    "payload/vector.svg",
    "payload/shortcut.lnk",
    "payload/settings.reg",
  ])("rejects dangerous package file %s", (relative) => {
    const fixture = createFixture();
    addFile(fixture.character, relative);
    const result = runValidator(fixture.root);
    expect(result.status).toBe(1);
    expect(`${result.stdout}\n${result.stderr}`).toContain("禁止的可执行或脚本文件");
  });

  it("rejects any otherwise harmless but undeclared extra file", () => {
    const fixture = createFixture();
    addFile(fixture.character, "notes.txt");
    const result = runValidator(fixture.root);
    expect(result.status).toBe(1);
    expect(`${result.stdout}\n${result.stderr}`).toContain("角色包包含未声明文件: notes.txt");
  });

  it("does not rewrite frames.json or index.json when validation fails", () => {
    const fixture = createFixture();
    const framesPath = join(fixture.character, "frames.json");
    const indexPath = join(fixture.root, "index.json");
    const originalFrames = readFileSync(framesPath, "utf8");
    const originalIndex = "index must remain unchanged\n";
    writeFileSync(indexPath, originalIndex, "utf8");
    addFile(fixture.character, "notes.txt");

    const result = runValidator(fixture.root);
    expect(result.status).toBe(1);
    expect(readFileSync(framesPath, "utf8")).toBe(originalFrames);
    expect(readFileSync(indexPath, "utf8")).toBe(originalIndex);
  });

  it("rejects a hard-linked index.json without modifying its other link", () => {
    const fixture = createFixture();
    const outsideIndex = join(fixture.root, "outside-index-target.json");
    const originalContent = "hard-link target must stay unchanged\n";
    writeFileSync(outsideIndex, originalContent, "utf8");
    linkSync(outsideIndex, join(fixture.root, "index.json"));

    const result = runValidator(fixture.root);
    expect(result.status).toBe(1);
    expect(`${result.stdout}\n${result.stderr}`).toContain("index.json 不能为硬链接");
    expect(readFileSync(outsideIndex, "utf8")).toBe(originalContent);
  });

  it("rejects a non-regular index.json target", () => {
    const fixture = createFixture();
    mkdirSync(join(fixture.root, "index.json"));
    const originalFrames = readFileSync(join(fixture.character, "frames.json"), "utf8");

    const result = runValidator(fixture.root);
    expect(result.status).toBe(1);
    expect(`${result.stdout}\n${result.stderr}`).toContain("index.json 必须为非链接的普通文件");
    expect(readFileSync(join(fixture.character, "frames.json"), "utf8")).toBe(originalFrames);
  });

  it("rejects a linked index.json without following it", ({ skip }) => {
    const fixture = createFixture();
    const outsideIndex = join(fixture.root, "outside-index-target.json");
    const originalContent = "symlink target must stay unchanged\n";
    writeFileSync(outsideIndex, originalContent, "utf8");
    try {
      symlinkSync(outsideIndex, join(fixture.root, "index.json"), "file");
    } catch (error) {
      if (areSymlinksUnavailable(error)) {
        skip();
        return;
      }
      throw error;
    }

    const result = runValidator(fixture.root);
    expect(result.status).toBe(1);
    expect(`${result.stdout}\n${result.stderr}`).toContain("index.json 必须为非链接的普通文件");
    expect(readFileSync(outsideIndex, "utf8")).toBe(originalContent);
  });

  it.runIf(process.platform === "win32")("rejects a junction used as the character root", ({ skip }) => {
    const fixture = createFixture();
    const linkedRoot = `${fixture.root}-junction`;
    temporaryRoots.unshift(linkedRoot);
    try {
      symlinkSync(fixture.root, linkedRoot, "junction");
    } catch (error) {
      if (areSymlinksUnavailable(error)) {
        skip();
        return;
      }
      throw error;
    }

    const result = runValidator(linkedRoot);
    expect(result.status).toBe(1);
    expect(`${result.stdout}\n${result.stderr}`).toContain("角色根目录必须为非链接的普通目录");
    expect(existsSync(join(fixture.root, "index.json"))).toBe(false);
  });

  it.runIf(process.platform === "win32")("rejects a frames.json file symlink before writing through it", ({ skip }) => {
    const fixture = createFixture();
    const externalFrames = join(fixture.root, "outside-frames.json");
    const originalContent = "outside content must stay unchanged\n";
    writeFileSync(externalFrames, originalContent, "utf8");
    rmSync(join(fixture.character, "frames.json"), { force: true });
    try {
      symlinkSync(externalFrames, join(fixture.character, "frames.json"), "file");
    } catch (error) {
      if (areSymlinksUnavailable(error)) {
        skip();
        return;
      }
      throw error;
    }

    const result = runValidator(fixture.root);
    expect(result.status).toBe(1);
    expect(`${result.stdout}\n${result.stderr}`).toContain("角色包不能包含符号链接或重解析点: frames.json");
    expect(readFileSync(externalFrames, "utf8")).toBe(originalContent);
  });

  it.runIf(process.platform === "win32")("rejects a frames.json directory junction before any external write", ({ skip }) => {
    const fixture = createFixture();
    const externalDirectory = join(fixture.root, "outside-frames-directory");
    const sentinel = join(externalDirectory, "sentinel.txt");
    mkdirSync(externalDirectory);
    writeFileSync(sentinel, "unchanged\n", "utf8");
    rmSync(join(fixture.character, "frames.json"), { force: true });
    try {
      symlinkSync(externalDirectory, join(fixture.character, "frames.json"), "junction");
    } catch (error) {
      if (areSymlinksUnavailable(error)) {
        skip();
        return;
      }
      throw error;
    }

    const result = runValidator(fixture.root);
    expect(result.status).toBe(1);
    expect(`${result.stdout}\n${result.stderr}`).toContain("角色包不能包含符号链接或重解析点: frames.json");
    expect(readFileSync(sentinel, "utf8")).toBe("unchanged\n");
  });

  it.runIf(process.platform === "win32")("stops the PowerShell packager before an unsafe archive is created", () => {
    const fixture = createFixture();
    addFile(fixture.character, "payload/runner.exe");
    const output = join(fixture.root, "packages");
    const result = spawnSync(
      "powershell.exe",
      [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        packager,
        "-CharacterId",
        "_placeholder",
        "-CharacterRoot",
        fixture.root,
        "-OutputDirectory",
        output,
      ],
      { encoding: "utf8" },
    );
    expect(result.status).not.toBe(0);
    expect(existsSync(join(output, "_placeholder_0.1.0.qipet"))).toBe(false);
  });

  it("requires preview and icon declarations to use lowercase png extensions", () => {
    const fixture = createFixture();
    const manifestPath = join(fixture.character, "manifest.json");
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as Record<string, unknown>;
    manifest.preview = "preview.PNG";
    writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
    const result = runValidator(fixture.root);
    expect(result.status).toBe(1);
    expect(`${result.stdout}\n${result.stderr}`).toContain("preview 必须使用小写 .png 扩展名");
  });

  it("uses the Rust UTF-8 byte limit for declared package paths", () => {
    const fixture = createFixture();
    const longPreview = `${"角".repeat(81)}.png`;
    renameSync(join(fixture.character, "preview.png"), join(fixture.character, longPreview));
    const manifest = readManifest(fixture.character);
    manifest.preview = longPreview;
    writeManifest(fixture.character, manifest);

    const result = runValidator(fixture.root);
    expect(result.status).toBe(1);
    expect(`${result.stdout}\n${result.stderr}`).toContain("preview 路径越出角色目录");
  });

  it("uses ASCII-only case folding to match the Rust package whitelist", () => {
    const fixture = createFixture();
    renameSync(join(fixture.character, "preview.png"), join(fixture.character, "ä.png"));
    const manifest = readManifest(fixture.character);
    manifest.preview = "Ä.png";
    writeManifest(fixture.character, manifest);

    const result = runValidator(fixture.root);
    expect(result.status).toBe(1);
    expect(`${result.stdout}\n${result.stderr}`).toContain("角色包包含未声明文件: ä.png");
  });

  it("requires version, author, and license for a custom character root", () => {
    const fixture = createFixture();
    const manifest = readManifest(fixture.character);
    delete manifest.version;
    delete manifest.author;
    delete manifest.license;
    writeManifest(fixture.character, manifest);

    const result = runValidator(fixture.root);
    const output = `${result.stdout}\n${result.stderr}`;
    expect(result.status).toBe(1);
    expect(output).toContain("version 必须为非空字符串");
    expect(output).toContain("author 必须为非空字符串");
    expect(output).toContain("license 必须为非空字符串");
  });

  it("rejects a package whose actual directory bytes exceed 512 MiB before generated writes", () => {
    const fixture = createFixture();
    const framesPath = join(fixture.character, "frames.json");
    const originalFrames = readFileSync(framesPath, "utf8");
    truncateSync(join(fixture.character, "metadata", "source.md"), maximumPackageBytes + 1);

    const result = runValidator(fixture.root);
    expect(result.status).toBe(1);
    expect(`${result.stdout}\n${result.stderr}`).toContain("角色包文件总大小超过 512 MiB 上限");
    expect(readFileSync(framesPath, "utf8")).toBe(originalFrames);
    expect(existsSync(join(fixture.root, "index.json"))).toBe(false);
  });

  it("rejects declared decoded pixels above the Rust limit before generated writes", () => {
    const fixture = createFixture();
    const framesPath = join(fixture.character, "frames.json");
    const originalFrames = readFileSync(framesPath, "utf8");
    const idleDirectory = join(fixture.character, "animations", "idle");
    const frame = readFileSync(join(idleDirectory, "idle_0001.png"));
    rmSync(idleDirectory, { recursive: true, force: true });
    mkdirSync(idleDirectory);
    for (let index = 1; index <= 17; index += 1) {
      writeFileSync(join(idleDirectory, `idle_${String(index).padStart(4, "0")}.png`), frame);
    }
    const manifest = readManifest(fixture.character);
    manifest.frameSize = { width: 4096, height: 4096 };
    writeManifest(fixture.character, manifest);

    const result = runValidator(fixture.root);
    expect(result.status).toBe(1);
    expect(`${result.stdout}\n${result.stderr}`).toContain("角色帧总解码像素超过 268435456 上限");
    expect(readFileSync(framesPath, "utf8")).toBe(originalFrames);
    expect(existsSync(join(fixture.root, "index.json"))).toBe(false);
  });

  it("rejects more than 2500 declared package files", { timeout: 30_000 }, () => {
    const fixture = createFixture();
    const sourceFrame = readFileSync(join(fixture.character, "animations", "idle", "idle_0001.png"));
    rmSync(join(fixture.character, "animations"), { recursive: true, force: true });
    const animations: Record<string, { path: string; fps: number; loop: boolean }> = {};
    let remaining = 2_501;
    let stateIndex = 0;
    while (remaining > 0) {
      const state = stateIndex === 0 ? "idle" : `state_${stateIndex}`;
      const count = Math.min(240, remaining);
      const directory = join(fixture.character, "animations", state);
      mkdirSync(directory, { recursive: true });
      animations[state] = { path: `animations/${state}`, fps: 1, loop: true };
      for (let frameIndex = 1; frameIndex <= count; frameIndex += 1) {
        writeFileSync(
          join(directory, `${state}_${String(frameIndex).padStart(4, "0")}.png`),
          sourceFrame,
        );
      }
      remaining -= count;
      stateIndex += 1;
    }
    const manifest = readManifest(fixture.character);
    manifest.frameSize = { width: 4096, height: 4096 };
    manifest.animations = animations;
    writeManifest(fixture.character, manifest);

    const result = runValidator(fixture.root);
    expect(result.status).toBe(1);
    expect(`${result.stdout}\n${result.stderr}`).toContain("超过上限 2500");
  });

  it("rejects traversal in a declared display asset before packaging", () => {
    const fixture = createFixture();
    const manifestPath = join(fixture.character, "manifest.json");
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as Record<string, unknown>;
    manifest.icon = "../icon.png";
    writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
    const result = runValidator(fixture.root);
    expect(result.status).toBe(1);
    expect(`${result.stdout}\n${result.stderr}`).toContain("icon 路径越出角色目录");
  });
});
