import type { AppSettings } from "../../core/settings/settingsSchema";

interface Props {
  settings: AppSettings;
  updaterConfigured: boolean | null;
  onPatch: (patch: Partial<AppSettings>) => void;
  onCheckUpdates: () => void;
  onAbout: () => void;
  onReset: () => void;
  onClose: () => void;
}

export function SettingsPanel({ settings, updaterConfigured, onPatch, onCheckUpdates, onAbout, onReset, onClose }: Props) {
  const confirmReset = () => {
    const confirmed = window.confirm("确定恢复默认设置吗？窗口位置、缩放、互动、置顶、全屏隐藏和更新偏好将重置；开机启动、透明度、音量、当前角色、角色包、日志和应用保持不变。");
    if (confirmed) onReset();
  };

  return (
    <aside className="settings-panel">
      <header><strong>七酱桌宠设置</strong><button onClick={onClose} aria-label="关闭设置">×</button></header>
      <fieldset className="settings-grid">
        <label><input type="checkbox" checked={settings.interactionsEnabled} onChange={(event) => onPatch({ interactionsEnabled: event.currentTarget.checked })} /> 启用互动</label>
        <label><input type="checkbox" checked={settings.alwaysOnTop} onChange={(event) => onPatch({ alwaysOnTop: event.currentTarget.checked })} /> 始终置顶</label>
        <label><input type="checkbox" checked={settings.autostart} onChange={(event) => onPatch({ autostart: event.currentTarget.checked })} /> 开机启动</label>
        <label><input type="checkbox" checked={settings.hideInFullscreen} onChange={(event) => onPatch({ hideInFullscreen: event.currentTarget.checked })} /> 全屏时自动隐藏</label>
        <label><input type="checkbox" checked={settings.automaticUpdateChecks} onChange={(event) => onPatch({ automaticUpdateChecks: event.currentTarget.checked })} /> 启动后自动检查更新</label>
        <label>音量 <input type="range" min="0" max="1" step="0.05" value={settings.volume} onChange={(event) => onPatch({ volume: event.currentTarget.valueAsNumber })} /></label>
      </fieldset>
      {updaterConfigured === null && <p role="status">正在读取更新服务配置…</p>}
      {updaterConfigured === false && <p role="status">更新服务尚未配置；当前版本仍可正常离线使用。</p>}
      <div className="panel-actions">
        <button disabled={updaterConfigured !== true} onClick={onCheckUpdates}>检查更新</button>
        <button onClick={onAbout}>关于七酱桌宠</button>
        <button onClick={confirmReset}>恢复默认设置</button>
      </div>
    </aside>
  );
}
