import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
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

class DeferredSettingsClient extends FakeSettingsClient {
  private readonly pending: Array<{
    action: DesktopControlAction;
    resolve: (result: DesktopControlResult) => void;
  }> = [];

  override request(action: DesktopControlAction, payload?: unknown): Promise<DesktopControlResult> {
    this.requests.push({ action, payload });
    return new Promise((resolve) => this.pending.push({ action, resolve }));
  }

  settleNext({ ok, patch, message }: { ok: boolean; patch?: Partial<typeof DEFAULT_SETTINGS>; message?: string }): void {
    const pending = this.pending.shift();
    if (!pending) throw new Error("没有待完成的设置请求");
    if (ok && patch) {
      this.current = {
        ...this.current,
        settings: { ...this.current.settings, ...patch },
        revision: this.current.revision + 1,
      };
    }
    pending.resolve({
      requestId: `deferred-${this.requests.length - this.pending.length}`,
      action: pending.action,
      ok,
      snapshot: this.current,
      ...(ok ? {} : { error: { code: "settings-apply-failed", message: message ?? "保存失败" } }),
    });
  }
}

afterEach(() => {
  cleanup();
  window.history.replaceState({}, "", "/");
});

describe("SettingsWindow", () => {
  it("forces the native close request after any pending save finishes", () => {
    const source = readFileSync(resolve(process.cwd(), "src/components/SettingsWindow/SettingsWindow.tsx"), "utf8");
    const capability = readFileSync(resolve(process.cwd(), "src-tauri/capabilities/settings.json"), "utf8");
    expect(source).toContain("onCloseRequested");
    expect(source).toContain("event.preventDefault()");
    expect(source).toContain("currentWindow.destroy()");
    expect(source).not.toContain("return getCurrentWindow().close()");
    expect(capability).toContain('"core:window:allow-destroy"');
  });

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

  it("serializes rapid slider changes and persists the final value", async () => {
    window.history.replaceState({}, "", "/?section=appearance");
    const client = new DeferredSettingsClient();
    render(<SettingsWindow client={client} onClose={vi.fn()} />);
    act(() => client.emitSnapshot());
    const slider = await screen.findByRole("slider", { name: "大小 100%" });

    fireEvent.change(slider, { target: { value: "1.1" } });
    await waitFor(() => expect(client.requests).toHaveLength(1));
    fireEvent.change(slider, { target: { value: "1.2" } });
    fireEvent.change(slider, { target: { value: "1.35" } });

    expect(slider).toHaveValue("1.35");
    expect(client.requests).toHaveLength(1);
    act(() => client.settleNext({ ok: true, patch: { scale: 1.1 } }));

    await waitFor(() => expect(client.requests).toHaveLength(2));
    expect(client.requests[1]).toEqual({ action: "patch-settings", payload: { patch: { scale: 1.35 } } });
    act(() => client.settleNext({ ok: true, patch: { scale: 1.35 } }));

    await waitFor(() => expect(screen.getByText("大小 135%")).toBeInTheDocument());
    expect(screen.getByText("更改会即时保存并立即生效。")).toBeInTheDocument();
  });

  it("blocks reset and updater actions while a settings patch is in flight", async () => {
    window.history.replaceState({}, "", "/?section=update");
    const client = new DeferredSettingsClient();
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
    fireEvent.click(await screen.findByRole("checkbox", { name: "自动检查更新" }));
    await waitFor(() => expect(client.requests).toHaveLength(1));

    const updateNow = screen.getByRole("button", { name: "立即更新" });
    expect(updateNow).toBeDisabled();
    fireEvent.click(updateNow);
    act(() => client.navigate("about"));
    const reset = await screen.findByRole("button", { name: "恢复默认设置" });
    expect(reset).toBeDisabled();
    fireEvent.click(reset);

    expect(screen.queryByRole("alertdialog", { name: "恢复默认设置？" })).not.toBeInTheDocument();
    expect(client.requests).toHaveLength(1);
    expect(client.requests[0].action).toBe("patch-settings");
    act(() => client.settleNext({ ok: true, patch: { automaticUpdateChecks: false } }));
  });

  it("does not close until the queued final slider value has been sent", async () => {
    window.history.replaceState({}, "", "/?section=appearance");
    const client = new DeferredSettingsClient();
    const onClose = vi.fn();
    render(<SettingsWindow client={client} onClose={onClose} />);
    act(() => client.emitSnapshot());
    const slider = await screen.findByRole("slider", { name: "大小 100%" });

    fireEvent.change(slider, { target: { value: "1.1" } });
    await waitFor(() => expect(client.requests).toHaveLength(1));
    fireEvent.change(slider, { target: { value: "1.4" } });
    const close = screen.getByRole("button", { name: "关闭七酱桌宠设置" });
    expect(close).toBeDisabled();
    fireEvent.click(close);
    expect(onClose).not.toHaveBeenCalled();

    act(() => client.settleNext({ ok: true, patch: { scale: 1.1 } }));
    await waitFor(() => expect(client.requests).toHaveLength(2));
    expect(client.requests[1]).toEqual({ action: "patch-settings", payload: { patch: { scale: 1.4 } } });
    expect(onClose).not.toHaveBeenCalled();
    act(() => client.settleNext({ ok: true, patch: { scale: 1.4 } }));

    await waitFor(() => expect(close).toBeEnabled());
    fireEvent.click(close);
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("drains a queued final patch before stopping the client on unmount", async () => {
    window.history.replaceState({}, "", "/?section=appearance");
    const client = new DeferredSettingsClient();
    const view = render(<SettingsWindow client={client} onClose={vi.fn()} />);
    act(() => client.emitSnapshot());
    const slider = await screen.findByRole("slider", { name: "大小 100%" });

    fireEvent.change(slider, { target: { value: "1.1" } });
    await waitFor(() => expect(client.requests).toHaveLength(1));
    fireEvent.change(slider, { target: { value: "1.45" } });
    view.unmount();
    expect(client.order).not.toContain("stop");

    act(() => client.settleNext({ ok: true, patch: { scale: 1.1 } }));
    await waitFor(() => expect(client.requests).toHaveLength(2));
    expect(client.requests[1]).toEqual({ action: "patch-settings", payload: { patch: { scale: 1.45 } } });
    act(() => client.settleNext({ ok: true, patch: { scale: 1.45 } }));
    await waitFor(() => expect(client.order).toContain("stop"));
  });

  it("reports the final patch failure and restores the canonical setting", async () => {
    window.history.replaceState({}, "", "/?section=appearance");
    const client = new DeferredSettingsClient();
    render(<SettingsWindow client={client} onClose={vi.fn()} />);
    act(() => client.emitSnapshot());
    const slider = await screen.findByRole("slider", { name: "大小 100%" });

    fireEvent.change(slider, { target: { value: "1.5" } });
    await waitFor(() => expect(client.requests).toHaveLength(1));
    act(() => client.settleNext({ ok: false, message: "无法保存大小设置" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("无法保存大小设置");
    expect(screen.getByText("大小 100%")).toBeInTheDocument();
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
