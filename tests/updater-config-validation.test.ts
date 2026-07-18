import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { afterEach, describe, expect, it } from "vitest";

const validator = resolve("scripts/validate-updater-config.mjs");
const temporaryDirectories: string[] = [];

function writeConfiguration(name: string, value: unknown): string {
  const directory = mkdtempSync(join(tmpdir(), "qijiang-updater-config-"));
  temporaryDirectories.push(directory);
  const path = join(directory, name);
  writeFileSync(path, JSON.stringify(value), "utf8");
  return path;
}

function validate(base: unknown, production: unknown) {
  const basePath = writeConfiguration("base.json", base);
  const productionPath = writeConfiguration("production.json", production);
  return spawnSync(process.execPath, [validator, "--base-config", basePath, "--production-config", productionPath], {
    encoding: "utf8",
  });
}

const safeBase = {
  bundle: { createUpdaterArtifacts: false },
  plugins: { updater: { pubkey: "", endpoints: [], windows: { installMode: "passive" } } },
};
const production = {
  bundle: { createUpdaterArtifacts: true },
  plugins: {
    updater: {
      pubkey: "fixture-public-key-text",
      endpoints: ["https://github.com/example/project/releases/latest/download/latest.json"],
      windows: { installMode: "passive" },
    },
  },
};

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) rmSync(directory, { recursive: true, force: true });
});

describe("Tauri updater configuration validation", () => {
  it("accepts the network-disabled base configuration and HTTPS production overlay", () => {
    const result = validate(safeBase, production);
    expect(result.status, result.stderr).toBe(0);
  });

  it("rejects a null updater object before a broken application can be built", () => {
    const result = validate({ ...safeBase, plugins: { updater: null } }, production);
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("must be an object and must never be null");
  });

  it("reports a missing updater field as a controlled configuration error", () => {
    const result = validate({ ...safeBase, plugins: {} }, production);
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("plugins.updater is missing");
  });

  it("rejects HTTP production endpoints and public-key filesystem paths", () => {
    const httpResult = validate(safeBase, {
      ...production,
      plugins: { updater: { ...production.plugins.updater, endpoints: ["http://updates.example.com/latest.json"] } },
    });
    expect(httpResult.status).toBe(1);
    expect(httpResult.stderr).toContain("must use HTTPS");

    const pathResult = validate(safeBase, {
      ...production,
      plugins: { updater: { ...production.plugins.updater, pubkey: "C:\\keys\\updater.key.pub" } },
    });
    expect(pathResult.status).toBe(1);
    expect(pathResult.stderr).toContain("key text, not a filesystem path");
  });
});
