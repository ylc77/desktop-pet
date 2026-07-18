import { describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { persistSelectionBeforeActivation } from "../src/core/character/selectionPersistence";
import { DEFAULT_SETTINGS, type AppSettings } from "../src/core/settings/settingsSchema";
import { SettingsTransactionQueue } from "../src/core/settings/settingsTransactionQueue";

describe("SettingsTransactionQueue", () => {
  it("keeps best-effort mutations, native effects, rollback, and quit draining on the app queue", () => {
    const source = readFileSync(resolve(process.cwd(), "src/app/App.tsx"), "utf8");
    expect(source).toContain("await saveSettings(next)");
    expect(source).toContain("await saveSettingsStrict(previous)");
    expect(source).toContain("原设置也未能完全恢复");
    expect(source).toContain("const flushSettingsAndClose");
    expect(source).toContain("if (shuttingDown.current) return Promise.resolve()");
    expect(source).toContain("const position = await saveWindowPosition()");
    expect(source).toContain("if (action === \"quit\") void flushSettingsAndClose()");
    expect(source).not.toContain("runSettingsTransaction(closeApp)");
    const startup = source.slice(source.indexOf("loaded = await loadSettings()"), source.indexOf("if (!ready) return;"));
    expect(startup).not.toContain("setAlwaysOnTop");
    expect(startup).toContain("restoreWindowPosition(loaded.position)");
    expect(source).toContain("const activated = await runSettingsTransaction(async () =>");
    expect(source).toContain("activatePrepared(prepared, false, preparedSettings)");
    expect(source).toContain("应用正在退出，角色切换已取消");
    expect(source).toContain("if (shuttingDown.current) return false;");
    expect(source).toContain("if (shuttingDown.current) throw new Error(\"应用正在退出，已取消更新安装\")");
    expect(source.match(/shuttingDown\.current/g)?.length ?? 0).toBeGreaterThanOrEqual(12);
  });

  it("executes mutations in FIFO order and continues after a rejection", async () => {
    const queue = new SettingsTransactionQueue();
    const order: string[] = [];
    const first = queue.run(async () => { order.push("first"); throw new Error("expected"); });
    const second = queue.run(async () => { order.push("second"); return 2; });

    await expect(first).rejects.toThrow("expected");
    await expect(second).resolves.toBe(2);
    expect(order).toEqual(["first", "second"]);
  });

  it("rolls back a superseded selection before a later settings mutation runs", async () => {
    const queue = new SettingsTransactionQueue();
    let canonical: AppSettings = DEFAULT_SETTINGS;
    let generation = 1;
    let releaseFirstWrite!: () => void;
    const writes: AppSettings[] = [];
    const persist = vi.fn(async (next: AppSettings) => {
      writes.push(next);
      if (writes.length === 1) await new Promise<void>((resolve) => { releaseFirstWrite = resolve; });
    });

    const oldSelection = queue.run(async () => {
      const previous = canonical;
      const next = { ...canonical, characterId: "old-selection" };
      return persistSelectionBeforeActivation({
        previous,
        next,
        persist,
        isCurrent: () => generation === 1,
        canRollback: () => true,
        activate: () => { canonical = next; },
      });
    });
    await vi.waitFor(() => expect(writes).toHaveLength(1));

    generation = 2;
    const laterScale = queue.run(async () => {
      const next = { ...canonical, scale: 1.35 };
      await persist(next);
      canonical = next;
    });
    releaseFirstWrite();

    await expect(oldSelection).resolves.toMatchObject({ ok: false, phase: "superseded" });
    await laterScale;
    expect(writes.map((value) => [value.characterId, value.scale])).toEqual([
      ["old-selection", DEFAULT_SETTINGS.scale],
      [DEFAULT_SETTINGS.characterId, DEFAULT_SETTINGS.scale],
      [DEFAULT_SETTINGS.characterId, 1.35],
    ]);
    expect(canonical).toMatchObject({ characterId: DEFAULT_SETTINGS.characterId, scale: 1.35 });
  });

  it("computes a later mutation from the character selection that actually committed", async () => {
    const queue = new SettingsTransactionQueue();
    let canonical: AppSettings = DEFAULT_SETTINGS;
    const persist = vi.fn().mockResolvedValue(undefined);

    const selection = queue.run(async () => {
      const previous = canonical;
      const next = { ...canonical, characterId: "selected" };
      return persistSelectionBeforeActivation({
        previous,
        next,
        persist,
        isCurrent: () => true,
        canRollback: () => true,
        activate: () => { canonical = next; },
      });
    });
    const laterAutostart = queue.run(async () => {
      const next = { ...canonical, autostart: true };
      await persist(next);
      canonical = next;
    });

    await expect(selection).resolves.toEqual({ ok: true });
    await laterAutostart;
    expect(canonical).toMatchObject({ characterId: "selected", autostart: true });
    expect(persist).toHaveBeenNthCalledWith(2, expect.objectContaining({ characterId: "selected", autostart: true }));
  });
});
