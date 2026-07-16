import type { UpdateDownloadProgress } from "../../core/updater/updaterTypes";

export function formatBytes(value: number): string {
  if (value < 1_024) return `${value} B`;
  if (value < 1_048_576) return `${(value / 1_024).toFixed(1)} KiB`;
  return `${(value / 1_048_576).toFixed(1)} MiB`;
}

export function UpdateProgress({ progress }: { progress: UpdateDownloadProgress }) {
  if (progress.totalBytes === null || progress.percent === null) {
    return <div className="update-progress" aria-live="polite"><span>正在下载并验证更新包…</span><progress /> 已下载 {formatBytes(progress.downloadedBytes)}（总大小未知）</div>;
  }
  return (
    <div className="update-progress" aria-live="polite">
      <span>正在下载并验证更新包…</span>
      <progress max="100" value={progress.percent} />
      {progress.percent}% · {formatBytes(progress.downloadedBytes)} / {formatBytes(progress.totalBytes)}
    </div>
  );
}
