import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import type { LoadedCharacter } from "../../core/character/types";
import { exportDiagnostics, openLogDirectory } from "../../core/diagnostics/diagnosticClient";
import { log } from "../../core/diagnostics/logger";
import type { AppSettings } from "../../core/settings/settingsSchema";
import type { UpdaterStore } from "../../core/updater/updaterStore";
import { UpdatePanel } from "../UpdatePanel/UpdatePanel";
import appIconUrl from "../../../app-icon.png";

interface Props {
  settings: AppSettings;
  character: LoadedCharacter;
  updaterStore: UpdaterStore;
  onPatch: (patch: Partial<AppSettings>) => void;
  onInstall: () => Promise<void>;
  onReset: () => Promise<void>;
  onClose: () => void;
}

export function AboutPanel({ settings, character, updaterStore, onPatch, onInstall, onReset, onClose }: Props) {
  const updater = useSyncExternalStore(updaterStore.subscribe, updaterStore.getSnapshot, updaterStore.getSnapshot);
  const [feedback, setFeedback] = useState<string | null>(null);
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; };
  }, []);

  const runExport = async () => {
    try {
      const result = await exportDiagnostics(settings, character, updater);
      if (mounted.current) setFeedback(`诊断包已导出到${result.location === "downloads" ? "下载目录" : "应用数据目录"}：${result.fileName}`);
    } catch (error) {
      log("warn", "导出诊断信息失败", error);
      if (mounted.current) setFeedback("诊断信息导出失败，请查看日志。");
    }
  };

  const confirmReset = async () => {
    const confirmed = window.confirm("确定恢复默认设置吗？窗口位置、缩放、互动、置顶、全屏隐藏和更新偏好将重置；开机启动、透明度、音量、当前角色、角色包、日志和应用保持不变。");
    if (!confirmed) return;
    try {
      await onReset();
      if (mounted.current) setFeedback("已恢复默认设置并将窗口移回可见区域。");
    } catch (error) {
      log("warn", "恢复默认设置失败", error);
      if (mounted.current) setFeedback("恢复默认设置未完全完成；部分设置可能已保存，请查看日志。");
    }
  };

  return (
    <aside className="about-panel">
      <header><strong>关于七酱桌宠</strong><button onClick={onClose} aria-label="关闭关于">×</button></header>
      <div className="about-scroll">
        <section>
          <div className="about-brand">
            <img className="about-app-icon" src={appIconUrl} alt="七酱桌宠白猫图标" />
            <h2>七酱桌宠</h2>
          </div>
          <p>版本：{updater.configuration?.currentVersion ?? "读取中…"}</p>
          <p>更新渠道：{updater.configuration?.channel ?? "beta"}</p>
          <p>上次检查：{settings.updateLastCheckAt ? new Date(settings.updateLastCheckAt).toLocaleString("zh-CN") : "尚未检查"}</p>
          <label className="about-update-toggle"><input type="checkbox" checked={settings.automaticUpdateChecks} onChange={(event) => onPatch({ automaticUpdateChecks: event.currentTarget.checked })} /> 启动后自动检查更新</label>
        </section>
        <UpdatePanel
          store={updaterStore}
          skippedVersion={settings.updateSkippedVersion}
          onSkip={async (version) => { if (await updaterStore.skip()) onPatch({ updateSkippedVersion: version }); }}
          onLater={async () => { await updaterStore.later(); }}
          onInstall={onInstall}
        />
        <section className="about-actions">
          <h3>诊断与恢复</h3>
          <button onClick={() => void openLogDirectory().catch((error) => log("warn", "打开日志目录失败", error))}>打开日志目录</button>
          <button onClick={() => void runExport()}>导出脱敏诊断信息</button>
          <button onClick={() => void confirmReset()} disabled={updater.status === "installing" || updater.status === "restarting"}>恢复默认设置</button>
          {feedback && <p role="status">{feedback}</p>}
        </section>
        <details><summary>隐私说明</summary><p>更新检查需要联网，但应用不包含遥测，不上传设置、角色资源、日志或诊断包。诊断导出只由你主动触发并保存在本机。</p></details>
        <details><summary>已知问题</summary><p>当前 Windows 安装包尚未进行 Authenticode 代码签名，可能触发 SmartScreen；{updater.configuration?.configured ? "自动更新已配置，但仍需完成真实两版本升级验证。" : "生产更新密钥和公网更新地址也尚未配置。"}</p></details>
      </div>
    </aside>
  );
}
