import type { UpdateDownloadProgress } from "../../core/updater/updaterTypes";

export function formatBytes(value: number): string {
  if (value < 1_024) return `${value} B`;
  if (value < 1_048_576) return `${(value / 1_024).toFixed(1)} KiB`;
  return `${(value / 1_048_576).toFixed(1)} MiB`;
}

export function UpdateProgress({ progress }: { progress: UpdateDownloadProgress }) {
  if (progress.totalBytes === null || progress.percent === null) {
    const description = `已下载 ${formatBytes(progress.downloadedBytes)}，总大小未知`;
    return (
      <div className="update-progress">
        <span>正在下载并验证更新包…</span>
        <progress aria-label="更新下载进度" aria-valuetext={description} />
        <span>{description}</span>
      </div>
    );
  }
  const description = `${progress.percent}%：${formatBytes(progress.downloadedBytes)} / ${formatBytes(progress.totalBytes)}`;
  return (
    <div className="update-progress">
      <span>正在下载并验证更新包…</span>
      <progress aria-label="更新下载进度" aria-valuetext={description} max="100" value={progress.percent} />
      <span>{description}</span>
    </div>
  );
}
