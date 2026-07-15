import type { LoadedCharacter } from "../../core/character/types";
import type { AppSettings } from "../../core/settings/settingsSchema";

interface Props {
  character: LoadedCharacter;
  settings: AppSettings;
  onPatch: (patch: Partial<AppSettings>) => void;
  onClose: () => void;
}

export function SettingsPanel({ character, settings, onPatch, onClose }: Props) {
  const skins = character.manifest.skins ?? { default: { name: "默认" } };
  return (
    <aside className="settings-panel">
      <header><strong>桌宠设置</strong><button onClick={onClose} aria-label="关闭设置">×</button></header>
      <fieldset className="settings-grid">
        <label><input type="checkbox" checked={settings.interactionsEnabled} onChange={(event) => onPatch({ interactionsEnabled: event.currentTarget.checked })} /> 启用互动</label>
        <label><input type="checkbox" checked={settings.alwaysOnTop} onChange={(event) => onPatch({ alwaysOnTop: event.currentTarget.checked })} /> 始终置顶</label>
        <label><input type="checkbox" checked={settings.autostart} onChange={(event) => onPatch({ autostart: event.currentTarget.checked })} /> 开机启动</label>
        <label><input type="checkbox" checked={settings.hideInFullscreen} onChange={(event) => onPatch({ hideInFullscreen: event.currentTarget.checked })} /> 全屏时自动隐藏</label>
        <label>皮肤 <select value={settings.skinId} onChange={(event) => onPatch({ skinId: event.currentTarget.value })}>{Object.entries(skins).map(([id, skin]) => <option key={id} value={id}>{skin.name}</option>)}</select></label>
        <label>音量 <input type="range" min="0" max="1" step="0.05" value={settings.volume} onChange={(event) => onPatch({ volume: event.currentTarget.valueAsNumber })} /></label>
      </fieldset>
    </aside>
  );
}
