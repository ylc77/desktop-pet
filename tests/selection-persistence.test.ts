import { describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { persistSelectionBeforeActivation } from "../src/core/character/selectionPersistence";
import { DEFAULT_SETTINGS } from "../src/core/settings/settingsSchema";

describe("character selection persistence gate", () => {
  it("does not activate until strict settings persistence completes", async () => {
    let finishPersist!: () => void;
    const persist = vi.fn(() => new Promise<void>((resolve) => { finishPersist = resolve; }));
    const activate = vi.fn();
    const next = { ...DEFAULT_SETTINGS, characterId: "personal" };
    const result = persistSelectionBeforeActivation({
      previous: DEFAULT_SETTINGS,
      next,
      persist,
      isCurrent: () => true,
      canRollback: () => true,
      activate,
    });

    expect(persist).toHaveBeenCalledWith(next);
    expect(activate).not.toHaveBeenCalled();
    finishPersist();

    await expect(result).resolves.toEqual({ ok: true });
    expect(activate).toHaveBeenCalledTimes(1);
  });

  it("returns a failed gate and never activates when strict persistence fails", async () => {
    const failure = new Error("native settings write failed");
    const activate = vi.fn();
    const persist = vi.fn()
      .mockRejectedValueOnce(failure)
      .mockResolvedValueOnce(undefined);
    const result = await persistSelectionBeforeActivation({
      previous: DEFAULT_SETTINGS,
      next: { ...DEFAULT_SETTINGS, characterId: "personal" },
      persist,
      isCurrent: () => true,
      canRollback: () => true,
      activate,
    });

    expect(result).toEqual({ ok: false, phase: "persist", error: failure });
    expect(persist).toHaveBeenNthCalledWith(2, DEFAULT_SETTINGS);
    expect(activate).not.toHaveBeenCalled();
  });

  it("restores the previous settings and does not activate a superseded selection", async () => {
    let current = true;
    const persist = vi.fn(async () => { current = false; });
    const activate = vi.fn();
    const next = { ...DEFAULT_SETTINGS, characterId: "personal" };
    const result = await persistSelectionBeforeActivation({
      previous: DEFAULT_SETTINGS,
      next,
      persist,
      isCurrent: () => current,
      canRollback: () => true,
      activate,
    });

    expect(result).toMatchObject({ ok: false, phase: "superseded" });
    expect(persist).toHaveBeenNthCalledWith(1, next);
    expect(persist).toHaveBeenNthCalledWith(2, DEFAULT_SETTINGS);
    expect(activate).not.toHaveBeenCalled();
  });

  it("does not rollback an old selection after a newer generation supersedes it", async () => {
    let generation = 1;
    const expectedGeneration = generation;
    const persist = vi.fn(async () => {
      generation = 2;
    });
    const activate = vi.fn();
    const next = { ...DEFAULT_SETTINGS, characterId: "old-request" };

    const result = await persistSelectionBeforeActivation({
      previous: DEFAULT_SETTINGS,
      next,
      persist,
      isCurrent: () => generation === expectedGeneration,
      canRollback: () => generation === expectedGeneration,
      activate,
    });

    expect(result).toMatchObject({ ok: false, phase: "superseded" });
    expect(persist).toHaveBeenCalledTimes(1);
    expect(persist).toHaveBeenCalledWith(next);
    expect(persist).not.toHaveBeenCalledWith(DEFAULT_SETTINGS);
    expect(activate).not.toHaveBeenCalled();
  });

  it("does not write at all when a queued selection is already superseded before it starts", async () => {
    const persist = vi.fn().mockResolvedValue(undefined);
    const activate = vi.fn();
    const result = await persistSelectionBeforeActivation({
      previous: DEFAULT_SETTINGS,
      next: { ...DEFAULT_SETTINGS, characterId: "stale-request" },
      persist,
      isCurrent: () => false,
      canRollback: () => true,
      activate,
    });

    expect(result).toMatchObject({ ok: false, phase: "superseded" });
    expect(persist).not.toHaveBeenCalled();
    expect(activate).not.toHaveBeenCalled();
  });

  it("gates App selection finalization and the success event behind strict persistence", () => {
    const source = readFileSync(resolve(process.cwd(), "src/app/App.tsx"), "utf8");
    const gate = source.indexOf("persistSelectionBeforeActivation({");
    const finalize = source.indexOf("await finalizeNativeCharacterSelection", gate);
    const success = source.indexOf("await notifySelectionChanged({ ...selection, ok: true })", finalize);
    expect(gate).toBeGreaterThan(-1);
    expect(finalize).toBeGreaterThan(gate);
    expect(success).toBeGreaterThan(finalize);
    expect(source.slice(gate, finalize)).toContain("notifySelectionChanged({ ...selection, ok: false");
    expect(source).toContain("runSettingsTransaction(async () =>");
    expect(source).toContain("canRollback: () => true");
  });
});
