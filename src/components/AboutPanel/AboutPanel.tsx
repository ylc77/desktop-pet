import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import type { LoadedCharacter } from "../../core/character/types";
import { exportDiagnostics, openLogDirectory } from "../../core/diagnostics/diagnosticClient";
import { log } from "../../core/diagnostics/logger";
import type { AppSettings } from "../../core/settings/settingsSchema";
import type { UpdaterStore } from "../../core/updater/updaterStore";
import { UpdatePanel } from "../UpdatePanel/UpdatePanel";
import appIconUrl from "../../../app-icon.png";
import type { DesktopCharacterSummary } from "../../core/desktopControl";

interface Props {
  settings: AppSettings;
  character: LoadedCharacter;
  updaterStore: UpdaterStore;
  onPatch: (patch: Partial<AppSettings>) => void;
  onInstall: () => Promise<void>;
  onReset: () => Promise<void>;
  onClose: () => void;
}

export interface AboutSupportContentProps {
  currentVersion: string;
  channel: "beta" | "stable";
  lastCheckAt: string | null;
  character: DesktopCharacterSummary | null;
  busy?: boolean;
  feedback?: { tone: "info" | "success" | "warning" | "danger"; message: string } | null;
  onCheckUpdates: () => void;
  onOpenLogDirectory: () => void;
  onExportDiagnostics: () => void;
  onRequestReset: () => void;
}

/** Pure about/support content used by the independent settings window. */
export function AboutSupportContent({
  currentVersion,
  channel,
  lastCheckAt,
  character,
  busy = false,
  feedback,
  onCheckUpdates,
  onOpenLogDirectory,
  onExportDiagnostics,
  onRequestReset,
}: AboutSupportContentProps) {
  return (
    <div className="about-support-content">
      <section aria-labelledby="about-brand-heading">
        <div className="about-brand">
          <img className="about-app-icon" src={appIconUrl} alt="七酱桌宠白猫图标" />
          <div>
            <h2 id="about-brand-heading">七酱桌宠</h2>
            <p>轻量、安静地陪伴在 Windows 桌面上。</p>
          </div>
        </div>
        <dl className="about-metadata">
          <div><dt>当前版本</dt><dd>{currentVersion}</dd></div>
          <div><dt>更新渠道</dt><dd>{channel}</dd></div>
          <div><dt>上次检查</dt><dd>{lastCheckAt ? new Date(lastCheckAt).toLocaleString("zh-CN") : "尚未检查"}</dd></div>
          {character && <div><dt>当前角色</dt><dd>{character.name} {character.version}</dd></div>}
        </dl>
        <button type="button" disabled={busy} onClick={onCheckUpdates}>检查更新</button>
      </section>

      <section aria-labelledby="support-heading">
        <h2 id="support-heading">日志与诊断</h2>
        <p>诊断文件只保存在本机，不会自动上传；是否发送由你决定。</p>
        <div className="panel-actions">
          <button type="button" disabled={busy} onClick={onOpenLogDirectory}>打开日志目录</button>
          <button type="button" disabled={busy} onClick={onExportDiagnostics}>导出脱敏诊断信息</button>
        </div>
        {feedback && <p className={`inline-feedback ${feedback.tone}`} role={feedback.tone === "danger" ? "alert" : "status"}>{feedback.message}</p>}
      </section>

      <details>
        <summary>隐私说明</summary>
        <p>更新检查需要联网，但应用不包含遥测，不上传设置、角色资源、日志或诊断包。诊断导出只由你主动触发并保存在本机。</p>
      </details>
      <details>
        <summary>已知问题</summary>
        <p>Windows 安装包的代码签名状态可能影响 SmartScreen 提示；自动更新仍需以真实两版本升级测试为准。</p>
      </details>

      <section className="danger-zone" aria-labelledby="advanced-heading">
        <h2 id="advanced-heading">高级</h2>
        <p>恢复默认设置不会删除已安装角色、外观包、日志、应用或用户文件。</p>
        <button type="button" className="danger" disabled={busy} onClick={onRequestReset}>恢复默认设置</button>
      </section>
    </div>
  );
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
