import { describe, expect, it, vi } from "vitest";
import { UpdaterStore } from "../src/core/updater/updaterStore";
import type { AvailableUpdate, UpdaterClient, UpdaterRuntimeConfiguration } from "../src/core/updater/updaterTypes";

const configured: UpdaterRuntimeConfiguration = {
  configured: true,
  status: "configured",
  applicationName: "七酱桌宠",
  currentVersion: "0.1.0",
  channel: "beta",
  endpointDomain: "updates.example.org",
  publicKeyFingerprint: "A".repeat(64),
  installMode: "passive",
};

const available: AvailableUpdate = {
  currentVersion: "0.1.0",
  version: "0.2.0-beta.1",
  notes: "测试更新",
  publishedAt: "2026-07-16T00:00:00Z",
  contentLength: 100,
};

function client(overrides: Partial<UpdaterClient> = {}): UpdaterClient {
  return {
    getConfiguration: vi.fn().mockResolvedValue(configured),
    check: vi.fn().mockResolvedValue(available),
    download: vi.fn().mockImplementation(async (onProgress) => onProgress({ chunkLength: 100, contentLength: 100 })),
    install: vi.fn().mockResolvedValue(undefined),
    relaunch: vi.fn().mockResolvedValue(undefined),
    cancelPending: vi.fn().mockResolvedValue(undefined),
    ...overrides,
  };
}

async function readyStore(mock = client()): Promise<{ store: UpdaterStore; mock: UpdaterClient }> {
  const store = new UpdaterStore(mock, () => new Date("2026-07-16T12:00:00Z"));
  await store.initialize();
  return { store, mock };
}

describe("UpdaterStore", () => {
  it("stays disabled and never checks when service is not configured", async () => {
    const mock = client({ getConfiguration: vi.fn().mockResolvedValue({ ...configured, configured: false, status: "notConfigured" }) });
    const store = new UpdaterStore(mock);
    await store.initialize();
    await store.check({ manual: true });
    expect(store.getSnapshot().status).toBe("disabled");
    expect(mock.check).not.toHaveBeenCalled();
  });

  it("reports no update", async () => {
    const { store } = await readyStore(client({ check: vi.fn().mockResolvedValue(null) }));
    await store.check({ manual: true });
    expect(store.getSnapshot().status).toBe("upToDate");
  });

  it("reports a strictly higher prerelease", async () => {
    const { store } = await readyStore();
    await store.check({ manual: true });
    expect(store.getSnapshot()).toMatchObject({ status: "available", update: { version: "0.2.0-beta.1" } });
  });

  it("rejects equal and lower mock responses defensively", async () => {
    for (const version of ["0.1.0", "0.0.9"]) {
      const { store } = await readyStore(client({ check: vi.fn().mockResolvedValue({ ...available, version }) }));
      await store.check({ manual: true });
      expect(store.getSnapshot().status).toBe("upToDate");
    }
  });

  it("respects skipped version automatically but manual check still shows it", async () => {
    const { store } = await readyStore();
    await store.check({ manual: false, skippedVersion: available.version });
    expect(store.getSnapshot().status).toBe("upToDate");
    await store.check({ manual: true, skippedVersion: available.version });
    expect(store.getSnapshot().status).toBe("available");
  });

  it("a higher version is not hidden by a previously skipped lower one", async () => {
    const { store } = await readyStore();
    await store.check({ manual: false, skippedVersion: "0.1.5" });
    expect(store.getSnapshot().status).toBe("available");
  });

  it("deduplicates repeated checks", async () => {
    let resolve!: (value: AvailableUpdate | null) => void;
    const check = vi.fn(() => new Promise<AvailableUpdate | null>((done) => { resolve = done; }));
    const { store } = await readyStore(client({ check }));
    const first = store.check({ manual: true });
    const second = store.check({ manual: true });
    expect(check).toHaveBeenCalledTimes(1);
    resolve(available);
    await Promise.all([first, second]);
    expect(store.getSnapshot().status).toBe("available");
  });

  it("tracks known download length without showing early 100 percent", async () => {
    let seenDuringCallback: number | null = null;
    const { store } = await readyStore(client({
      download: vi.fn().mockImplementation(async (onProgress) => {
        onProgress({ chunkLength: 100, contentLength: 100 });
        seenDuringCallback = store.getSnapshot().progress?.percent ?? null;
      }),
    }));
    await store.check({ manual: true });
    await store.download();
    expect(seenDuringCallback).toBe(99);
    expect(store.getSnapshot()).toMatchObject({ status: "readyToInstall", progress: { percent: 100 } });
  });

  it("uses indeterminate progress when Content-Length is unavailable", async () => {
    const { store } = await readyStore(client({
      check: vi.fn().mockResolvedValue({ ...available, contentLength: null }),
      download: vi.fn().mockImplementation(async (onProgress) => onProgress({ chunkLength: 12, contentLength: null })),
    }));
    await store.check({ manual: true });
    await store.download();
    expect(store.getSnapshot().progress).toEqual({ downloadedBytes: 12, totalBytes: null, percent: null });
  });

  it("deduplicates download and prevents a simultaneous check", async () => {
    let finish!: () => void;
    const download = vi.fn(() => new Promise<void>((done) => { finish = done; }));
    const mock = client({ download });
    const { store } = await readyStore(mock);
    await store.check({ manual: true });
    const first = store.download();
    const second = store.download();
    await expect(store.check({ manual: true })).rejects.toMatchObject({ category: "busy" });
    expect(download).toHaveBeenCalledTimes(1);
    finish();
    await Promise.all([first, second]);
  });

  it("does not discard a verified download by checking again", async () => {
    const mock = client();
    const { store } = await readyStore(mock);
    await store.check({ manual: true });
    await store.download();
    await expect(store.check({ manual: true })).rejects.toMatchObject({ category: "busy" });
    expect(mock.check).toHaveBeenCalledTimes(1);
    expect(store.getSnapshot().status).toBe("readyToInstall");
  });

  it.each([
    [{ category: "timeout", message: "timeout" }, "timeout"],
    [{ category: "endpointNotFound", message: "404" }, "endpointNotFound"],
    [{ category: "invalidMetadata", message: "json" }, "invalidMetadata"],
    [{ category: "invalidSignature", message: "signature" }, "invalidSignature"],
    [{ category: "downloadInterrupted", message: "interrupted" }, "downloadInterrupted"],
  ] as const)("preserves categorized updater failures %#", async (failure, category) => {
    const { store } = await readyStore(client({ check: vi.fn().mockRejectedValue(failure) }));
    await store.check({ manual: true });
    expect(store.getSnapshot()).toMatchObject({ status: "error", error: { category } });
  });

  it("does not reuse stale update metadata after a later check fails", async () => {
    const check = vi.fn()
      .mockResolvedValueOnce(available)
      .mockRejectedValueOnce({ category: "timeout", message: "timeout" })
      .mockResolvedValueOnce(null);
    const { store } = await readyStore(client({ check }));
    await store.check({ manual: true });
    expect(store.getSnapshot().update?.version).toBe(available.version);
    await store.check({ manual: true });
    expect(store.getSnapshot()).toMatchObject({ status: "error", update: null });
    await store.retry();
    expect(check).toHaveBeenCalledTimes(3);
    expect(store.getSnapshot().status).toBe("upToDate");
  });

  it("downloads again after a recoverable failure", async () => {
    const download = vi.fn().mockRejectedValueOnce({ category: "downloadInterrupted", message: "stopped" }).mockResolvedValueOnce(undefined);
    const { store } = await readyStore(client({ download }));
    await store.check({ manual: true });
    await store.download();
    expect(store.getSnapshot().status).toBe("error");
    await store.retry();
    await store.download();
    expect(store.getSnapshot().status).toBe("readyToInstall");
  });

  it("saves state before install and relaunches only after success", async () => {
    const order: string[] = [];
    const mock = client({
      install: vi.fn(async () => { order.push("install"); }),
      relaunch: vi.fn(async () => { order.push("relaunch"); }),
    });
    const { store } = await readyStore(mock);
    await store.check({ manual: true });
    await store.download();
    await store.install({ beforeInstall: async () => { order.push("save"); } });
    expect(order).toEqual(["save", "install", "relaunch"]);
    expect(store.getSnapshot().status).toBe("restarting");
  });

  it("does not relaunch when state flush or installation fails", async () => {
    for (const beforeInstallFails of [true, false]) {
      const mock = client({ install: beforeInstallFails ? vi.fn() : vi.fn().mockRejectedValue({ category: "installFailed", message: "failed" }) });
      const { store } = await readyStore(mock);
      await store.check({ manual: true });
      await store.download();
      await store.install({ beforeInstall: async () => { if (beforeInstallFails) throw new Error("save failed"); } });
      expect(mock.relaunch).not.toHaveBeenCalled();
      expect(store.getSnapshot().status).toBe("error");
      await store.retry();
      expect(store.getSnapshot().status).toBe("readyToInstall");
      expect(mock.download).toHaveBeenCalledTimes(1);
    }
  });

  it("only cancels a pending non-running update", async () => {
    const { store, mock } = await readyStore();
    await store.check({ manual: true });
    await store.cancelPending();
    expect(mock.cancelPending).toHaveBeenCalledTimes(1);
    expect(store.getSnapshot().status).toBe("cancelled");
  });

  it("records bounded state transitions with reasons", async () => {
    const { store } = await readyStore(client({ check: vi.fn().mockResolvedValue(null) }));
    await store.check({ manual: true });
    expect(store.getSnapshot().transitions.every((entry) => entry.reason.length > 0)).toBe(true);
    expect(store.getSnapshot().transitions.length).toBeLessThanOrEqual(24);
  });
});
