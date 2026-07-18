import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SettingsWindow } from "../src/components/SettingsWindow/SettingsWindow";
import { DEFAULT_SETTINGS } from "../src/core/settings/settingsSchema";
import type {
  DesktopControlAction,
  DesktopControlResult,
  DesktopControlSnapshot,
  SettingsSectionId,
  SettingsWindowClientLike,
} from "../src/core/desktopControl";

function snapshot(overrides: Partial<DesktopControlSnapshot> = {}): DesktopControlSnapshot {
  return {
    settings: DEFAULT_SETTINGS,
    updater: {
      status: "idle",
      reason: "ready",
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
    },
    character: { id: "_placeholder", name: "中性占位角色", version: "1.0.0", author: "七酱桌宠" },
    revision: 1,
    ...overrides,
  };
}

class FakeSettingsClient implements SettingsWindowClientLike {
  readonly order: string[] = [];
  readonly requests: { action: DesktopControlAction; payload?: unknown }[] = [];
  private snapshotListeners = new Set<(value: DesktopControlSnapshot) => void>();
  private navigationListeners = new Set<(value: SettingsSectionId) => void>();
  current = snapshot();

  async start(): Promise<void> { this.order.push("start"); }
  stop(): void { this.order.push("stop"); }
  subscribeSnapshot(listener: (value: DesktopControlSnapshot) => void): () => void {
    this.order.push("subscribe-snapshot");
    this.snapshotListeners.add(listener);
    return () => this.snapshotListeners.delete(listener);
  }
  subscribeNavigation(listener: (value: SettingsSectionId) => void): () => void {
    this.order.push("subscribe-navigation");
    this.navigationListeners.add(listener);
    return () => this.navigationListeners.delete(listener);
  }
  async request(action: DesktopControlAction, payload?: unknown): Promise<DesktopControlResult> {
    this.requests.push({ action, payload });
    return { requestId: `request-${this.requests.length}`, action, ok: true, snapshot: this.current };
  }
  emitSnapshot(value = this.current): void { this.current = value; this.snapshotListeners.forEach((listener) => listener(value)); }
  navigate(section: SettingsSectionId): void { this.navigationListeners.forEach((listener) => listener(section)); }
}

afterEach(() => {
  cleanup();
  window.history.replaceState({}, "", "/");
});

describe("SettingsWindow", () => {
  it("subscribes before ready and does not expose editable controls before a canonical snapshot", async () => {
    const client = new FakeSettingsClient();
    render(<SettingsWindow client={client} onClose={vi.fn()} />);
    expect(screen.getByText("正在读取设置…")).toBeInTheDocument();
    expect(screen.queryByRole("checkbox", { name: "开机启动" })).not.toBeInTheDocument();
    expect(client.order.slice(0, 3)).toEqual(["subscribe-snapshot", "subscribe-navigation", "start"]);

    act(() => client.emitSnapshot());
    expect(await screen.findByRole("checkbox", { name: "开机启动" })).toBeEnabled();
  });

  it("uses a whitelisted URL section before a navigation event can arrive", async () => {
    window.history.replaceState({}, "", "/?surface=settings&section=about");
    const client = new FakeSettingsClient();
    render(<SettingsWindow client={client} onClose={vi.fn()} />);
    act(() => client.emitSnapshot());
    expect(await screen.findByRole("heading", { name: "关于与支持" })).toBeInTheDocument();

    act(() => client.navigate("behavior"));
    expect(await screen.findByRole("heading", { name: "行为" })).toHaveFocus();
  });

  it("sends setting changes to main instead of writing local state", async () => {
    const client = new FakeSettingsClient();
    render(<SettingsWindow client={client} onClose={vi.fn()} />);
    act(() => client.emitSnapshot());
    fireEvent.click(await screen.findByRole("checkbox", { name: "开机启动" }));
    await waitFor(() => expect(client.requests[0]).toEqual({ action: "patch-settings", payload: { patch: { autostart: true } } }));
  });

  it("focuses Cancel first and returns focus after Escape closes reset confirmation", async () => {
    window.history.replaceState({}, "", "/?section=about");
    const client = new FakeSettingsClient();
    render(<SettingsWindow client={client} onClose={vi.fn()} />);
    act(() => client.emitSnapshot());
    const trigger = await screen.findByRole("button", { name: "恢复默认设置" });
    trigger.focus();
    fireEvent.click(trigger);
    const dialog = screen.getByRole("alertdialog", { name: "恢复默认设置？" });
    expect(screen.getByRole("button", { name: "取消" })).toHaveFocus();
    fireEvent.keyDown(dialog, { key: "Escape" });
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    expect(trigger).toHaveFocus();
    expect(client.requests).toHaveLength(0);
  });

  it("renders updater actions from the serialized main-window snapshot", async () => {
    window.history.replaceState({}, "", "/?section=update");
    const client = new FakeSettingsClient();
    const available = snapshot({
      updater: {
        ...snapshot().updater,
        status: "available",
        update: {
          currentVersion: "0.1.2-beta.1",
          version: "0.1.3-beta.1",
          notes: "提升稳定性",
          publishedAt: "2026-07-18T00:00:00.000Z",
          contentLength: 100,
        },
      },
    });
    render(<SettingsWindow client={client} onClose={vi.fn()} />);
    act(() => client.emitSnapshot(available));
    expect(await screen.findByText("0.1.2-beta.1 → 0.1.3-beta.1")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "立即更新" }));
    await waitFor(() => expect(client.requests.at(-1)?.action).toBe("update-now"));
  });
});
