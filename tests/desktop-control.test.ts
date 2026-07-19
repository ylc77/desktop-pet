import { describe, expect, it, vi } from "vitest";
import type { UnlistenFn } from "@tauri-apps/api/event";
import { DEFAULT_SETTINGS } from "../src/core/settings/settingsSchema";
import type { UpdaterSnapshot } from "../src/core/updater/updaterTypes";
import {
  desktopControlEvents,
  DesktopControlActionError,
  MainControlCoordinator,
  SettingsWindowClient,
  type DesktopControlRequest,
  type DesktopControlResult,
  type DesktopControlSnapshot,
  type DesktopControlTransport,
} from "../src/core/desktopControl";

class FakeTransport implements DesktopControlTransport {
  readonly emissions: { target: string; eventName: string; payload: unknown }[] = [];
  private readonly listeners = new Map<string, Set<(payload: unknown) => void>>();

  async listen<T>(eventName: string, listener: (payload: T) => void): Promise<UnlistenFn> {
    const listeners = this.listeners.get(eventName) ?? new Set();
    const wrapped = listener as (payload: unknown) => void;
    listeners.add(wrapped);
    this.listeners.set(eventName, listeners);
    return () => listeners.delete(wrapped);
  }

  async emitTo<T>(target: string, eventName: string, payload: T): Promise<void> {
    this.emissions.push({ target, eventName, payload });
  }

  dispatch<T>(eventName: string, payload: T): void {
    this.listeners.get(eventName)?.forEach((listener) => listener(payload));
  }
}

function updater(status: UpdaterSnapshot["status"] = "idle"): UpdaterSnapshot {
  return {
    status,
    reason: "test",
    transitionedAt: "2026-07-18T00:00:00.000Z",
    configuration: {
      configured: true,
      status: "configured",
      applicationName: "七酱桌宠",
      currentVersion: "0.1.2-beta.1",
      channel: "beta",
      endpointDomain: "github.com",
      publicKeyFingerprint: "A".repeat(64),
      installMode: "passive",
    },
    update: null,
    progress: null,
    error: null,
    transitions: [],
  };
}

function snapshot(revision = 1): DesktopControlSnapshot {
  return {
    settings: DEFAULT_SETTINGS,
    updater: updater(),
    character: { id: "_placeholder", name: "中性占位角色", version: "1.0.0", author: "七酱桌宠", fitScale: 1 },
    revision,
  };
}

describe("SettingsWindowClient", () => {
  it("attaches every listener before announcing that the settings window is ready", async () => {
    const transport = new FakeTransport();
    const client = new SettingsWindowClient(transport);
    const snapshots: DesktopControlSnapshot[] = [];
    const navigation: string[] = [];
    client.subscribeSnapshot((value) => snapshots.push(value));
    client.subscribeNavigation((value) => navigation.push(value));

    await client.start();
    expect(transport.emissions[0]).toMatchObject({ target: "main", eventName: desktopControlEvents.ready, payload: { protocolVersion: 1 } });

    transport.dispatch(desktopControlEvents.snapshot, snapshot());
    transport.dispatch(desktopControlEvents.navigate, { section: "about" });
    transport.dispatch(desktopControlEvents.navigate, { section: "unknown" });
    expect(snapshots).toHaveLength(1);
    expect(navigation).toEqual(["about"]);
    client.stop();
  });

  it("correlates results by request id and forwards the canonical snapshot", async () => {
    const transport = new FakeTransport();
    const client = new SettingsWindowClient(transport);
    const snapshots: DesktopControlSnapshot[] = [];
    client.subscribeSnapshot((value) => snapshots.push(value));
    await client.start();

    const pending = client.request("patch-settings", { patch: { alwaysOnTop: false } });
    await vi.waitFor(() => expect(transport.emissions.some((item) => item.eventName === desktopControlEvents.request)).toBe(true));
    const request = transport.emissions.find((item) => item.eventName === desktopControlEvents.request)!.payload as DesktopControlRequest;
    const next = { ...snapshot(2), settings: { ...DEFAULT_SETTINGS, alwaysOnTop: false } };
    transport.dispatch<DesktopControlResult>(desktopControlEvents.result, { requestId: request.requestId, action: request.action, ok: true, snapshot: next });

    await expect(pending).resolves.toMatchObject({ ok: true, requestId: request.requestId });
    expect(snapshots.at(-1)?.settings.alwaysOnTop).toBe(false);
    client.stop();
  });
});

describe("MainControlCoordinator", () => {
  it("publishes one canonical snapshot and returns a correlated result", async () => {
    const transport = new FakeTransport();
    let current = snapshot();
    const handleRequest = vi.fn(async (request: DesktopControlRequest) => {
      if (request.action === "patch-settings") current = { ...current, revision: 2, settings: { ...current.settings, alwaysOnTop: false } };
    });
    const coordinator = new MainControlCoordinator({ getSnapshot: () => current, handleRequest, transport });
    await coordinator.start();

    transport.dispatch(desktopControlEvents.ready, { protocolVersion: 1 });
    await vi.waitFor(() => expect(transport.emissions.some((item) => item.eventName === desktopControlEvents.snapshot)).toBe(true));
    const request: DesktopControlRequest = { requestId: "request-1", action: "patch-settings", payload: { patch: { alwaysOnTop: false } } };
    transport.dispatch(desktopControlEvents.request, request);
    await vi.waitFor(() => expect(transport.emissions.some((item) => item.eventName === desktopControlEvents.result)).toBe(true));

    const result = transport.emissions.find((item) => item.eventName === desktopControlEvents.result)!.payload as DesktopControlResult;
    expect(handleRequest).toHaveBeenCalledWith(request);
    expect(result).toMatchObject({ requestId: "request-1", action: "patch-settings", ok: true });
    expect(result.snapshot?.settings.alwaysOnTop).toBe(false);
    coordinator.stop();
  });

  it("only exposes an approved public error message", async () => {
    const transport = new FakeTransport();
    const coordinator = new MainControlCoordinator({
      getSnapshot: () => snapshot(),
      handleRequest: async () => { throw new Error("C:\\Users\\77\\secret-token.txt"); },
      transport,
    });
    await coordinator.start();
    transport.dispatch(desktopControlEvents.request, { requestId: "request-2", action: "export-diagnostics" });
    await vi.waitFor(() => expect(transport.emissions.some((item) => item.eventName === desktopControlEvents.result)).toBe(true));
    const result = transport.emissions.find((item) => item.eventName === desktopControlEvents.result)!.payload as DesktopControlResult;
    expect(result.ok).toBe(false);
    expect(result.error?.message).toBe("操作未完成，请重试或查看日志。");
    expect(JSON.stringify(result)).not.toContain("secret-token");
    coordinator.stop();
  });

  it("allows handlers to return a safe, user-facing recovery message", async () => {
    const transport = new FakeTransport();
    const coordinator = new MainControlCoordinator({
      getSnapshot: () => snapshot(),
      handleRequest: async () => { throw new DesktopControlActionError("autostart-failed", "无法修改开机启动，请检查 Windows 权限后重试。"); },
      transport,
    });
    await coordinator.start();
    transport.dispatch(desktopControlEvents.request, { requestId: "request-3", action: "patch-settings" });
    await vi.waitFor(() => expect(transport.emissions.some((item) => item.eventName === desktopControlEvents.result)).toBe(true));
    const result = transport.emissions.find((item) => item.eventName === desktopControlEvents.result)!.payload as DesktopControlResult;
    expect(result.error).toEqual({ code: "autostart-failed", message: "无法修改开机启动，请检查 Windows 权限后重试。" });
    coordinator.stop();
  });
});
