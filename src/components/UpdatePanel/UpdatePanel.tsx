import { useSyncExternalStore } from "react";
import type { UpdaterStore } from "../../core/updater/updaterStore";
import type { UpdaterFailureCategory } from "../../core/updater/updaterTypes";
import { formatBytes, UpdateProgress } from "./UpdateProgress";

const failureText: Record<UpdaterFailureCategory, string> = {
  notConfigured: "更新服务尚未配置。",
  offline: "当前无法连接更新服务，请检查网络后重试。",
  timeout: "更新服务响应超时，请稍后重试。",
  endpointNotFound: "更新信息暂时不可用（404）。",
  invalidMetadata: "更新信息格式无效，已停止更新。",
  invalidSignature: "更新包签名验证失败，已阻止安装。",
  downloadInterrupted: "更新包下载中断，请重试。",
  permissionDenied: "系统拒绝了更新操作，请检查权限。",
  installFailed: "更新安装失败，应用不会重启。",
  unsupported: "当前环境不支持应用更新。",
  busy: "已有更新任务正在进行。",
  unknown: "更新操作失败，请查看脱敏日志。",
};

function formatDate(value: string | null): string {
  if (!value) return "未提供";
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? "未提供" : parsed.toLocaleString("zh-CN");
}

interface Props {
  store: UpdaterStore;
  skippedVersion: string | null;
  onSkip: (version: string) => void;
  onLater: () => void;
  onInstall: () => Promise<void>;
}

export function UpdatePanel({ store, skippedVersion, onSkip, onLater, onInstall }: Props) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const update = snapshot.update;
  const busy = snapshot.status === "checking" || snapshot.status === "downloading" || snapshot.status === "readyToInstall" || snapshot.status === "installing" || snapshot.status === "restarting";

  return (
    <section className="update-panel" aria-label="应用更新">
      <div className="panel-row">
        <strong>应用更新</strong>
        <button disabled={busy || !snapshot.configuration?.configured} onClick={() => void store.check({ manual: true })}>检查更新</button>
      </div>
      {snapshot.status === "disabled" && <p>更新服务尚未配置。当前版本仍可正常离线使用。</p>}
      {snapshot.status === "idle" && <p>尚未检查更新。</p>}
      {snapshot.status === "checking" && <p role="status">正在安全检查更新…</p>}
      {snapshot.status === "upToDate" && <p role="status">当前已经是最新版本。</p>}
      {update && ["available", "downloading", "readyToInstall", "installing", "restarting", "error"].includes(snapshot.status) && (
        <div className="update-details">
          <p><b>{update.currentVersion}</b> → <b>{update.version}</b>{skippedVersion === update.version ? "（此前已跳过）" : ""}</p>
          <p>发布日期：{formatDate(update.publishedAt)}</p>
          {update.contentLength !== null && update.contentLength > 0 && <p>安装包大小：{formatBytes(update.contentLength)}</p>}
          {update.notes && <p className="update-notes">{update.notes}</p>}
        </div>
      )}
      {snapshot.status === "available" && update && (
        <div className="panel-actions">
          <button onClick={() => void store.download()}>下载更新</button>
          <button onClick={onLater}>稍后提醒</button>
          <button onClick={() => onSkip(update.version)}>跳过此版本</button>
        </div>
      )}
      {snapshot.status === "downloading" && snapshot.progress && <UpdateProgress progress={snapshot.progress} />}
      {snapshot.status === "readyToInstall" && (
        <div>
          <p role="status">下载和签名验证已完成。安装时应用将退出并重新启动。</p>
          <button onClick={() => void onInstall()}>立即安装并重启</button>
        </div>
      )}
      {snapshot.status === "installing" && <p role="status">正在启动 Windows 被动安装流程…</p>}
      {snapshot.status === "restarting" && <p role="status">安装完成，正在重新启动七酱桌宠…</p>}
      {snapshot.status === "cancelled" && <p role="status">本次更新已取消。</p>}
      {snapshot.status === "error" && snapshot.error && (
        <div className="update-error" role="alert">
          <p>{failureText[snapshot.error.category]}</p>
          <button disabled={busy} onClick={() => void store.retry()}>重试</button>
        </div>
      )}
    </section>
  );
}
