import type { UnlistenFn } from "@tauri-apps/api/event";
import {
  desktopControlEvents,
  isDesktopControlResult,
  isSettingsSectionId,
  MAIN_WINDOW_LABEL,
  type DesktopControlAction,
  type DesktopControlRequest,
  type DesktopControlResult,
  type DesktopControlSnapshot,
  type SettingsNavigatePayload,
  type SettingsSectionId,
  type SettingsWindowReadyPayload,
} from "./types";
import { tauriDesktopControlTransport, type DesktopControlTransport } from "./transport";

type SnapshotListener = (snapshot: DesktopControlSnapshot) => void;
type NavigationListener = (section: SettingsSectionId) => void;

interface PendingRequest {
  resolve: (result: DesktopControlResult) => void;
  reject: (error: Error) => void;
}

export interface SettingsWindowClientLike {
  start(): Promise<void>;
  stop(): void;
  subscribeSnapshot(listener: SnapshotListener): () => void;
  subscribeNavigation(listener: NavigationListener): () => void;
  request(action: DesktopControlAction, payload?: unknown): Promise<DesktopControlResult>;
}

export class SettingsWindowClient implements SettingsWindowClientLike {
  private readonly snapshotListeners = new Set<SnapshotListener>();
  private readonly navigationListeners = new Set<NavigationListener>();
  private readonly pending = new Map<string, PendingRequest>();
  private unlisteners: UnlistenFn[] = [];
  private startPromise: Promise<void> | null = null;
  private started = false;
  private sequence = 0;
  private lifecycle = 0;

  constructor(private readonly transport: DesktopControlTransport = tauriDesktopControlTransport) {}

  start(): Promise<void> {
    if (this.started) return Promise.resolve();
    if (this.startPromise) {
      const pendingStart = this.startPromise;
      return pendingStart.catch(() => undefined).then(() => this.started ? undefined : this.start());
    }
    const lifecycle = ++this.lifecycle;
    this.startPromise = this.attachListeners()
      .then(async (unlisteners) => {
        if (lifecycle !== this.lifecycle) {
          unlisteners.forEach((unlisten) => unlisten());
          return;
        }
        this.unlisteners.push(...unlisteners);
        this.started = true;
        const payload: SettingsWindowReadyPayload = { protocolVersion: 1 };
        await this.transport.emitTo(MAIN_WINDOW_LABEL, desktopControlEvents.ready, payload);
      })
      .catch((error) => {
        if (lifecycle === this.lifecycle) this.detachListeners();
        throw error;
      })
      .finally(() => { this.startPromise = null; });
    return this.startPromise;
  }

  stop(): void {
    this.lifecycle += 1;
    this.started = false;
    this.detachListeners();
    const error = new Error("设置窗口已关闭");
    this.pending.forEach(({ reject }) => reject(error));
    this.pending.clear();
  }

  subscribeSnapshot(listener: SnapshotListener): () => void {
    this.snapshotListeners.add(listener);
    return () => this.snapshotListeners.delete(listener);
  }

  subscribeNavigation(listener: NavigationListener): () => void {
    this.navigationListeners.add(listener);
    return () => this.navigationListeners.delete(listener);
  }

  async request(action: DesktopControlAction, payload?: unknown): Promise<DesktopControlResult> {
    await this.start();
    this.sequence += 1;
    const requestId = `settings-${Date.now().toString(36)}-${this.sequence.toString(36)}`;
    const request: DesktopControlRequest = { requestId, action, ...(payload === undefined ? {} : { payload }) };
    const result = new Promise<DesktopControlResult>((resolve, reject) => {
      this.pending.set(requestId, { resolve, reject });
    });
    try {
      await this.transport.emitTo(MAIN_WINDOW_LABEL, desktopControlEvents.request, request);
    } catch (error) {
      this.pending.delete(requestId);
      throw error;
    }
    return result;
  }

  private attachListeners(): Promise<UnlistenFn[]> {
    return Promise.all([
      this.transport.listen<DesktopControlSnapshot>(desktopControlEvents.snapshot, (snapshot) => {
        this.snapshotListeners.forEach((listener) => listener(snapshot));
      }),
      this.transport.listen<DesktopControlResult>(desktopControlEvents.result, (result) => {
        if (!isDesktopControlResult(result)) return;
        if (result.snapshot) this.snapshotListeners.forEach((listener) => listener(result.snapshot!));
        const pending = this.pending.get(result.requestId);
        if (!pending) return;
        this.pending.delete(result.requestId);
        pending.resolve(result);
      }),
      this.transport.listen<SettingsNavigatePayload>(desktopControlEvents.navigate, (payload) => {
        if (!isSettingsSectionId(payload?.section)) return;
        this.navigationListeners.forEach((listener) => listener(payload.section));
      }),
    ]);
  }

  private detachListeners(): void {
    this.unlisteners.splice(0).forEach((unlisten) => unlisten());
  }
}
