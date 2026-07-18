import type { UnlistenFn } from "@tauri-apps/api/event";
import {
  desktopControlEvents,
  isDesktopControlRequest,
  MAIN_WINDOW_LABEL,
  SETTINGS_WINDOW_LABEL,
  type DesktopControlRequest,
  type DesktopControlResult,
  type DesktopControlSnapshot,
  type DesktopControlPublicError,
} from "./types";
import { tauriDesktopControlTransport, type DesktopControlTransport } from "./transport";

export interface MainControlCoordinatorOptions {
  getSnapshot: () => DesktopControlSnapshot;
  handleRequest: (request: DesktopControlRequest) => Promise<void>;
  transport?: DesktopControlTransport;
}

export class DesktopControlActionError extends Error {
  constructor(public readonly code: string, public readonly publicMessage: string) {
    super(publicMessage);
    this.name = "DesktopControlActionError";
  }
}

function publicError(error: unknown): DesktopControlPublicError {
  if (error instanceof DesktopControlActionError) {
    return { code: error.code, message: error.publicMessage };
  }
  return { code: "operation-failed", message: "操作未完成，请重试或查看日志。" };
}

/**
 * Main-window adapter for the settings bridge. App.tsx owns the handlers and
 * calls publishSnapshot whenever its canonical state changes.
 */
export class MainControlCoordinator {
  private readonly transport: DesktopControlTransport;
  private unlisteners: UnlistenFn[] = [];
  private started = false;
  private requestQueue: Promise<void> = Promise.resolve();

  constructor(private readonly options: MainControlCoordinatorOptions) {
    this.transport = options.transport ?? tauriDesktopControlTransport;
  }

  async start(): Promise<void> {
    if (this.started) return;
    const unlisteners = await Promise.all([
      this.transport.listen(desktopControlEvents.ready, () => { void this.publishSnapshot().catch(() => undefined); }),
      this.transport.listen<DesktopControlRequest>(desktopControlEvents.request, (request) => {
        if (!isDesktopControlRequest(request)) return;
        this.requestQueue = this.requestQueue.then(() => this.process(request)).catch(() => undefined);
      }),
    ]);
    this.unlisteners.push(...unlisteners);
    this.started = true;
  }

  stop(): void {
    this.started = false;
    this.unlisteners.splice(0).forEach((unlisten) => unlisten());
  }

  async publishSnapshot(): Promise<void> {
    await this.transport.emitTo(SETTINGS_WINDOW_LABEL, desktopControlEvents.snapshot, this.options.getSnapshot());
  }

  private async process(request: DesktopControlRequest): Promise<void> {
    let result: DesktopControlResult;
    try {
      await this.options.handleRequest(request);
      result = { requestId: request.requestId, action: request.action, ok: true, snapshot: this.options.getSnapshot() };
    } catch (error) {
      result = { requestId: request.requestId, action: request.action, ok: false, snapshot: this.options.getSnapshot(), error: publicError(error) };
    }
    await this.transport.emitTo(SETTINGS_WINDOW_LABEL, desktopControlEvents.result, result);
    await this.publishSnapshot();
  }
}

export { MAIN_WINDOW_LABEL };
