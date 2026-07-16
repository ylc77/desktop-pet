import { sanitizeDiagnosticText } from "../diagnostics/logger";
import { isVersionNewer } from "./updaterPolicy";
import type {
  CheckOptions,
  InstallPreparation,
  UpdaterClient,
  UpdaterErrorInfo,
  UpdaterFailureCategory,
  UpdaterSnapshot,
  UpdaterStatus,
} from "./updaterTypes";

const MAX_TRANSITIONS = 24;
const knownCategories = new Set<UpdaterFailureCategory>([
  "notConfigured", "offline", "timeout", "endpointNotFound", "invalidMetadata",
  "invalidSignature", "downloadInterrupted", "permissionDenied", "installFailed",
  "unsupported", "busy", "unknown",
]);

function classifyError(error: unknown): UpdaterErrorInfo {
  if (error && typeof error === "object") {
    const candidate = error as { category?: unknown; message?: unknown };
    if (typeof candidate.category === "string" && knownCategories.has(candidate.category as UpdaterFailureCategory)) {
      return { category: candidate.category as UpdaterFailureCategory, message: sanitizeDiagnosticText(String(candidate.message ?? "更新操作失败")) };
    }
  }
  const raw = error instanceof Error ? error.message : String(error ?? "更新操作失败");
  const value = raw.toLowerCase();
  const category: UpdaterFailureCategory = value.includes("404") ? "endpointNotFound"
    : value.includes("timeout") || value.includes("timed out") ? "timeout"
      : value.includes("signature") ? "invalidSignature"
        : value.includes("json") || value.includes("metadata") ? "invalidMetadata"
          : value.includes("permission") || value.includes("access denied") ? "permissionDenied"
            : value.includes("network") || value.includes("offline") || value.includes("connect") ? "offline"
              : "unknown";
  return { category, message: sanitizeDiagnosticText(raw) };
}

export class UpdaterStore {
  private snapshot: UpdaterSnapshot;
  private readonly listeners = new Set<() => void>();
  private inFlight: { kind: "initialize" | "check" | "download" | "install"; promise: Promise<unknown> } | null = null;
  private retryTarget: "check" | "download" | "install" | null = null;

  constructor(private readonly client: UpdaterClient, private readonly now: () => Date = () => new Date()) {
    const at = this.now().toISOString();
    this.snapshot = {
      status: "disabled",
      reason: "更新配置尚未读取",
      transitionedAt: at,
      configuration: null,
      update: null,
      progress: null,
      error: null,
      transitions: [],
    };
  }

  getSnapshot = (): UpdaterSnapshot => this.snapshot;
  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  private publish(next: UpdaterSnapshot): void {
    this.snapshot = next;
    this.listeners.forEach((listener) => listener());
  }

  private transition(status: UpdaterStatus, reason: string, patch: Partial<UpdaterSnapshot> = {}): void {
    const at = this.now().toISOString();
    const transition = { from: this.snapshot.status, to: status, reason, at };
    this.publish({
      ...this.snapshot,
      ...patch,
      status,
      reason,
      transitionedAt: at,
      transitions: [...this.snapshot.transitions, transition].slice(-MAX_TRANSITIONS),
    });
  }

  initialize(): Promise<void> {
    if (this.snapshot.configuration) return Promise.resolve();
    if (this.inFlight?.kind === "initialize") return this.inFlight.promise as Promise<void>;
    const promise = this.client.getConfiguration()
      .then((configuration) => {
        if (!configuration.configured) {
          this.transition("disabled", configuration.status === "unsupported" ? "当前环境不支持应用更新" : "更新服务尚未配置", { configuration });
          return;
        }
        this.transition("idle", "更新服务已配置", { configuration, error: null });
      })
      .catch((error) => {
        const info = classifyError(error);
        this.retryTarget = "check";
        this.transition("error", "读取更新配置失败", { error: info });
      })
      .finally(() => { if (this.inFlight?.promise === promise) this.inFlight = null; });
    this.inFlight = { kind: "initialize", promise };
    return promise;
  }

  check(options: CheckOptions): Promise<void> {
    if (!this.snapshot.configuration) {
      return this.initialize().then(() => this.snapshot.configuration ? this.check(options) : undefined);
    }
    if (this.inFlight?.kind === "check") return this.inFlight.promise as Promise<void>;
    if (this.inFlight) return Promise.reject({ category: "busy", message: "已有更新任务正在进行" });
    if (this.snapshot.status === "readyToInstall") return Promise.reject({ category: "busy", message: "已下载的更新正在等待安装" });
    if (!this.snapshot.configuration?.configured) {
      this.transition("disabled", "更新服务尚未配置", { error: { category: "notConfigured", message: "更新服务尚未配置" } });
      return Promise.resolve();
    }
    this.retryTarget = null;
    this.transition("checking", options.manual ? "用户手动检查更新" : "按启动策略自动检查更新", { error: null, progress: null, update: null });
    const promise = this.client.check()
      .then((update) => {
        if (!update || !isVersionNewer(update.version, update.currentVersion)) {
          this.transition("upToDate", "当前已经是最新版本", { update: null });
          return;
        }
        if (!options.manual && options.skippedVersion === update.version) {
          this.transition("upToDate", `已按偏好跳过版本 ${update.version}`, { update });
          return;
        }
        this.transition("available", `发现新版本 ${update.version}`, { update });
      })
      .catch((error) => {
        const info = classifyError(error);
        this.retryTarget = "check";
        this.transition("error", options.manual ? "手动检查更新失败" : "自动检查更新失败", { error: info });
      })
      .finally(() => { if (this.inFlight?.promise === promise) this.inFlight = null; });
    this.inFlight = { kind: "check", promise };
    return promise;
  }

  download(): Promise<void> {
    if (this.inFlight?.kind === "download") return this.inFlight.promise as Promise<void>;
    if (this.inFlight) return Promise.reject({ category: "busy", message: "已有更新任务正在进行" });
    if (this.snapshot.status !== "available" || !this.snapshot.update) return Promise.reject({ category: "busy", message: "当前没有可下载的更新" });
    let downloadedBytes = 0;
    let totalBytes: number | null = this.snapshot.update.contentLength;
    this.retryTarget = null;
    this.transition("downloading", "开始下载并验证更新包", { progress: { downloadedBytes: 0, totalBytes, percent: totalBytes ? 0 : null }, error: null });
    const promise = this.client.download(({ chunkLength, contentLength }) => {
      downloadedBytes += Math.max(0, chunkLength);
      if (contentLength !== null && contentLength > 0) totalBytes = contentLength;
      const percent = totalBytes ? Math.min(99, Math.floor((downloadedBytes / totalBytes) * 100)) : null;
      this.publish({ ...this.snapshot, progress: { downloadedBytes, totalBytes, percent } });
    })
      .then(() => this.transition("readyToInstall", "更新包下载及签名验证完成", {
        progress: { downloadedBytes, totalBytes, percent: totalBytes ? 100 : null },
      }))
      .catch((error) => {
        const info = classifyError(error);
        this.retryTarget = "download";
        this.transition("error", "更新包下载或验证失败", { error: info });
      })
      .finally(() => { if (this.inFlight?.promise === promise) this.inFlight = null; });
    this.inFlight = { kind: "download", promise };
    return promise;
  }

  install(preparation: InstallPreparation): Promise<void> {
    if (this.inFlight?.kind === "install") return this.inFlight.promise as Promise<void>;
    if (this.inFlight) return Promise.reject({ category: "busy", message: "已有更新任务正在进行" });
    if (this.snapshot.status !== "readyToInstall") return Promise.reject({ category: "busy", message: "更新包尚未准备完成" });
    this.retryTarget = null;
    this.transition("installing", "保存本地状态并开始安装更新", { error: null });
    const promise = preparation.beforeInstall()
      .then(() => this.client.install())
      .then(() => {
        this.transition("restarting", "更新安装完成，准备重新启动");
        return this.client.relaunch();
      })
      .catch((error) => {
        const info = classifyError(error);
        this.retryTarget = "install";
        this.transition("error", "更新安装失败，应用不会重启", { error: { ...info, category: info.category === "unknown" ? "installFailed" : info.category } });
      })
      .finally(() => { if (this.inFlight?.promise === promise) this.inFlight = null; });
    this.inFlight = { kind: "install", promise };
    return promise;
  }

  retry(): Promise<void> {
    if (this.retryTarget === "install" && this.snapshot.update) {
      this.retryTarget = null;
      this.transition("readyToInstall", "用户准备重新尝试安装更新", { error: null });
      return Promise.resolve();
    }
    if (this.retryTarget === "download" && this.snapshot.update) {
      this.retryTarget = null;
      this.transition("available", "用户准备重试更新", { error: null });
      return Promise.resolve();
    }
    this.retryTarget = null;
    return this.check({ manual: true });
  }

  later(): void {
    if (this.snapshot.update) this.transition("available", "用户选择稍后提醒");
  }

  cancelPending(): Promise<void> {
    if (this.inFlight) return Promise.reject({ category: "busy", message: "进行中的下载或安装不能安全取消" });
    this.retryTarget = null;
    return this.client.cancelPending().then(() => this.transition("cancelled", "用户取消了尚未开始下载的更新", { update: null, progress: null }));
  }
}
