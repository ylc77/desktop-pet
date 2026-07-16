import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { StrictMode } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { UpdatePanel } from "../src/components/UpdatePanel/UpdatePanel";
import { AboutPanel } from "../src/components/AboutPanel/AboutPanel";
import { SettingsPanel } from "../src/components/SettingsPanel/SettingsPanel";
import { DEFAULT_SETTINGS } from "../src/core/settings/settingsSchema";
import { UpdaterStore } from "../src/core/updater/updaterStore";
import type { AvailableUpdate, UpdaterClient, UpdaterRuntimeConfiguration } from "../src/core/updater/updaterTypes";
import { makeCharacter } from "./fixtures";

const configuration: UpdaterRuntimeConfiguration = {
  configured: true,
  status: "configured",
  applicationName: "七酱桌宠",
  currentVersion: "0.1.0",
  channel: "beta",
  endpointDomain: "updates.example.org",
  publicKeyFingerprint: "B".repeat(64),
  installMode: "passive",
};
const update: AvailableUpdate = {
  currentVersion: "0.1.0",
  version: "0.2.0-beta.1",
  notes: "修复稳定性问题",
  publishedAt: "2026-07-16T00:00:00Z",
  contentLength: null,
};

function mockClient(overrides: Partial<UpdaterClient> = {}): UpdaterClient {
  return {
    getConfiguration: vi.fn().mockResolvedValue(configuration),
    check: vi.fn().mockResolvedValue(update),
    download: vi.fn().mockResolvedValue(undefined),
    install: vi.fn().mockResolvedValue(undefined),
    relaunch: vi.fn().mockResolvedValue(undefined),
    cancelPending: vi.fn().mockResolvedValue(undefined),
    ...overrides,
  };
}

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe("UpdatePanel", () => {
  it("shows a safe not-configured state without starting a request", async () => {
    const api = mockClient({ getConfiguration: vi.fn().mockResolvedValue({ ...configuration, configured: false, status: "notConfigured" }) });
    const store = new UpdaterStore(api);
    await store.initialize();
    render(<UpdatePanel store={store} skippedVersion={null} onSkip={vi.fn()} onLater={vi.fn()} onInstall={vi.fn()} />);
    expect(screen.getByText(/更新服务尚未配置/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "检查更新" })).toBeDisabled();
    expect(api.check).not.toHaveBeenCalled();
  });

  it("shows current/new versions, notes and publication date", async () => {
    const store = new UpdaterStore(mockClient({
      check: vi.fn().mockResolvedValue({ ...update, contentLength: 100 }),
    }));
    await store.initialize();
    await store.check({ manual: true });
    render(<UpdatePanel store={store} skippedVersion={null} onSkip={vi.fn()} onLater={vi.fn()} onInstall={vi.fn()} />);
    expect(screen.getByText("0.1.0")).toBeInTheDocument();
    expect(screen.getByText("0.2.0-beta.1")).toBeInTheDocument();
    expect(screen.getByText("安装包大小：100 B")).toBeInTheDocument();
    expect(screen.getByText("修复稳定性问题")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "下载更新" })).toBeEnabled();
  });

  it("renders release notes as text rather than HTML", async () => {
    const api = mockClient({ check: vi.fn().mockResolvedValue({ ...update, notes: "<img src=x onerror=alert(1)>" }) });
    const store = new UpdaterStore(api);
    await store.initialize();
    await store.check({ manual: true });
    const view = render(<UpdatePanel store={store} skippedVersion={null} onSkip={vi.fn()} onLater={vi.fn()} onInstall={vi.fn()} />);
    expect(view.container.querySelector("img")).toBeNull();
    expect(screen.getByText("<img src=x onerror=alert(1)>")).toBeInTheDocument();
  });

  it("marks a previously skipped version but still shows it on manual check", async () => {
    const store = new UpdaterStore(mockClient());
    await store.initialize();
    await store.check({ manual: true, skippedVersion: update.version });
    render(<UpdatePanel store={store} skippedVersion={update.version} onSkip={vi.fn()} onLater={vi.fn()} onInstall={vi.fn()} />);
    expect(screen.getByText(/此前已跳过/)).toBeInTheDocument();
  });

  it("invokes later and skip callbacks without cancelling the store", async () => {
    const store = new UpdaterStore(mockClient());
    const later = vi.fn();
    const skip = vi.fn();
    await store.initialize();
    await store.check({ manual: true });
    render(<UpdatePanel store={store} skippedVersion={null} onSkip={skip} onLater={later} onInstall={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: "稍后提醒" }));
    fireEvent.click(screen.getByRole("button", { name: "跳过此版本" }));
    expect(later).toHaveBeenCalledTimes(1);
    expect(skip).toHaveBeenCalledWith(update.version);
    expect(store.getSnapshot().status).toBe("available");
  });

  it("uses indeterminate progress when total size is unknown", async () => {
    let finish!: () => void;
    const api = mockClient({ download: vi.fn((onProgress) => {
      onProgress({ chunkLength: 42, contentLength: null });
      return new Promise<void>((resolve) => { finish = resolve; });
    }) });
    const store = new UpdaterStore(api);
    await store.initialize();
    await store.check({ manual: true });
    render(<UpdatePanel store={store} skippedVersion={null} onSkip={vi.fn()} onLater={vi.fn()} onInstall={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: "下载更新" }));
    expect(await screen.findByText(/总大小未知/)).toBeInTheDocument();
    expect(screen.queryByText("100%")).not.toBeInTheDocument();
    finish();
    await waitFor(() => expect(store.getSnapshot().status).toBe("readyToInstall"));
  });

  it("displays a signature failure and never offers install", async () => {
    const api = mockClient({ download: vi.fn().mockRejectedValue({ category: "invalidSignature", message: "bad signature" }) });
    const store = new UpdaterStore(api);
    await store.initialize();
    await store.check({ manual: true });
    render(<UpdatePanel store={store} skippedVersion={null} onSkip={vi.fn()} onLater={vi.fn()} onInstall={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: "下载更新" }));
    expect(await screen.findByText(/签名验证失败/)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "立即安装并重启" })).not.toBeInTheDocument();
  });

  it("disables another check after a verified download is ready", async () => {
    const store = new UpdaterStore(mockClient());
    await store.initialize();
    await store.check({ manual: true });
    await store.download();
    render(<UpdatePanel store={store} skippedVersion={null} onSkip={vi.fn()} onLater={vi.fn()} onInstall={vi.fn()} />);
    expect(screen.getByRole("button", { name: "检查更新" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "立即安装并重启" })).toBeEnabled();
  });

  it("unsubscribes cleanly when the component unmounts", async () => {
    const store = new UpdaterStore(mockClient());
    await store.initialize();
    const view = render(<UpdatePanel store={store} skippedVersion={null} onSkip={vi.fn()} onLater={vi.fn()} onInstall={vi.fn()} />);
    view.unmount();
    await store.check({ manual: true });
    expect(store.getSnapshot().status).toBe("available");
  });

  it("About shows native version/channel without production debug controls", async () => {
    const store = new UpdaterStore(mockClient());
    await store.initialize();
    render(<AboutPanel
      settings={DEFAULT_SETTINGS}
      character={makeCharacter()}
      updaterStore={store}
      onPatch={vi.fn()}
      onInstall={vi.fn()}
      onReset={vi.fn()}
      onClose={vi.fn()}
    />);
    expect(screen.getByRole("heading", { name: "七酱桌宠" })).toBeInTheDocument();
    expect(screen.getByText("版本：0.1.0")).toBeInTheDocument();
    expect(screen.getByText("更新渠道：beta")).toBeInTheDocument();
    expect(screen.getByText(/自动更新已配置，但仍需完成真实两版本升级验证/)).toBeInTheDocument();
    expect(screen.queryByText(/生产更新密钥和公网更新地址也尚未配置/)).not.toBeInTheDocument();
    expect(screen.queryByText(/编辑 endpoint|强制签名通过|允许降级/i)).not.toBeInTheDocument();
  });

  it("keeps asynchronous About feedback working under StrictMode effect replay", async () => {
    vi.spyOn(window, "confirm").mockReturnValue(true);
    const store = new UpdaterStore(mockClient());
    const reset = vi.fn().mockResolvedValue(undefined);
    await store.initialize();
    render(<StrictMode><AboutPanel
      settings={DEFAULT_SETTINGS}
      character={makeCharacter()}
      updaterStore={store}
      onPatch={vi.fn()}
      onInstall={vi.fn()}
      onReset={reset}
      onClose={vi.fn()}
    /></StrictMode>);

    fireEvent.click(screen.getByRole("button", { name: "恢复默认设置" }));
    expect(await screen.findByText(/已恢复默认设置并将窗口移回可见区域/)).toBeInTheDocument();
    expect(reset).toHaveBeenCalledTimes(1);
  });

  it("requires confirmation before restoring defaults from Settings", () => {
    const reset = vi.fn();
    const confirm = vi.spyOn(window, "confirm").mockReturnValueOnce(false).mockReturnValueOnce(true);
    render(<SettingsPanel
      settings={DEFAULT_SETTINGS}
      onPatch={vi.fn()}
      onCheckUpdates={vi.fn()}
      onAbout={vi.fn()}
      onReset={reset}
      onClose={vi.fn()}
    />);

    fireEvent.click(screen.getByRole("button", { name: "恢复默认设置" }));
    expect(reset).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "恢复默认设置" }));
    expect(confirm).toHaveBeenCalledTimes(2);
    expect(reset).toHaveBeenCalledTimes(1);
  });
});
