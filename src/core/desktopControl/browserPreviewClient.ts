import packageJson from "../../../package.json";
import { appSettingsSchema, DEFAULT_SETTINGS, resetSettingsPreservingCharacter } from "../settings/settingsSchema";
import type {
  DesktopControlAction,
  DesktopControlResult,
  DesktopControlSnapshot,
  SettingsSectionId,
} from "./types";
import type { SettingsWindowClientLike } from "./settingsWindowClient";

type SnapshotListener = (snapshot: DesktopControlSnapshot) => void;
type NavigationListener = (section: SettingsSectionId) => void;

function initialPreviewSnapshot(): DesktopControlSnapshot {
  return {
    settings: DEFAULT_SETTINGS,
    updater: {
      status: "disabled",
      reason: "更新服务尚未配置",
      transitionedAt: new Date(0).toISOString(),
      configuration: {
        configured: false,
        status: "notConfigured",
        applicationName: "七酱桌宠",
        currentVersion: packageJson.version,
        channel: "stable",
        endpointDomain: null,
        publicKeyFingerprint: null,
        installMode: "passive",
      },
      update: null,
      progress: null,
      error: null,
      transitions: [],
    },
    character: {
      id: "_placeholder",
      name: "中性占位角色",
      version: "1.0.0",
      author: "七酱桌宠",
    },
    revision: 1,
  };
}

/**
 * Explicit local preview transport used only by `?preview=1` browser QA.
 * Packaged Tauri windows always use SettingsWindowClient and the main-owner bridge.
 */
export class BrowserPreviewSettingsClient implements SettingsWindowClientLike {
  private readonly snapshotListeners = new Set<SnapshotListener>();
  private readonly navigationListeners = new Set<NavigationListener>();
  private snapshot = initialPreviewSnapshot();
  private sequence = 0;

  async start(): Promise<void> {
    queueMicrotask(() => this.publish());
  }

  stop(): void {}

  subscribeSnapshot(listener: SnapshotListener): () => void {
    this.snapshotListeners.add(listener);
    return () => this.snapshotListeners.delete(listener);
  }

  subscribeNavigation(listener: NavigationListener): () => void {
    this.navigationListeners.add(listener);
    return () => this.navigationListeners.delete(listener);
  }

  async request(action: DesktopControlAction, payload?: unknown): Promise<DesktopControlResult> {
    this.sequence += 1;
    const requestId = `browser-preview-${this.sequence}`;
    if (action === "patch-settings" && payload && typeof payload === "object" && "patch" in payload) {
      this.snapshot = {
        ...this.snapshot,
        settings: appSettingsSchema.parse({ ...this.snapshot.settings, ...(payload as { patch: object }).patch }),
        revision: this.snapshot.revision + 1,
      };
      this.publish();
    } else if (action === "reset-settings") {
      this.snapshot = {
        ...this.snapshot,
        settings: resetSettingsPreservingCharacter(this.snapshot.settings),
        revision: this.snapshot.revision + 1,
      };
      this.publish();
    } else if (action === "open-appearance") {
      const url = new URL(window.location.href);
      url.searchParams.set("surface", "appearance");
      url.searchParams.delete("section");
      window.location.assign(url);
    }
    return { requestId, action, ok: true, snapshot: this.snapshot };
  }

  private publish(): void {
    this.snapshotListeners.forEach((listener) => listener(this.snapshot));
  }
}
