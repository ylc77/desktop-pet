import type { AppSettings } from "../../core/settings/settingsSchema";
import {
  MAX_PET_SIZE_PERCENT,
  minimumPetSizePercent,
  petPercentToScale,
  petScaleToPercent,
} from "../../core/animation/petScale";

interface Props {
  position: { x: number; y: number };
  settings: AppSettings;
  fitScale: number;
  developerToolsAllowed: boolean;
  onPatch: (patch: Partial<AppSettings>) => void;
  onAction: (action: "reload" | "reset" | "hide" | "quit" | "settings" | "developer" | "appearance" | "check-updates" | "about") => void;
  onClose: () => void;
}

export function ContextMenu({ position, settings, fitScale, developerToolsAllowed, onPatch, onAction, onClose }: Props) {
  const viewportPadding = 8;
  const left = Math.max(viewportPadding, Math.min(position.x, window.innerWidth - 205 - viewportPadding));
  const top = Math.max(viewportPadding, Math.min(position.y, window.innerHeight - 390));

  return (
    <div className="menu-backdrop" onPointerDown={onClose} onContextMenu={(event) => event.preventDefault()}>
      <section
        className="context-menu"
        style={{ left, top, maxHeight: window.innerHeight - top - viewportPadding }}
        onPointerDown={(event) => event.stopPropagation()}
      >
        <button onClick={() => onPatch({ animationsPaused: !settings.animationsPaused })}>{settings.animationsPaused ? "继续动画" : "暂停动画"}</button>
        <label>大小 {petScaleToPercent(settings.scale, fitScale)}% <input type="range" min={minimumPetSizePercent(fitScale)} max={MAX_PET_SIZE_PERCENT} step="1" value={petScaleToPercent(settings.scale, fitScale)} onChange={(e) => onPatch({ scale: petPercentToScale(e.currentTarget.valueAsNumber, fitScale) })} /></label>
        <label>透明度 <input type="range" min="0.2" max="1" step="0.05" value={settings.opacity} onChange={(e) => onPatch({ opacity: e.currentTarget.valueAsNumber })} /></label>
        <button onClick={() => onAction("appearance")}>外观中心</button>
        <button onClick={() => onPatch({ alwaysOnTop: !settings.alwaysOnTop })}>{settings.alwaysOnTop ? "关闭置顶" : "开启置顶"}</button>
        <button onClick={() => onPatch({ autostart: !settings.autostart })}>{settings.autostart ? "关闭开机启动" : "开启开机启动"}</button>
        <button onClick={() => onPatch({ facing: settings.facing === "left" ? "right" : "left" })}>朝向：{settings.facing === "left" ? "左" : "右"}</button>
        <button onClick={() => onAction("settings")}>设置</button>
        <button onClick={() => onAction("check-updates")}>检查更新</button>
        <button onClick={() => onAction("about")}>关于七酱桌宠</button>
        {developerToolsAllowed && <button onClick={() => onAction("developer")}>开发者面板</button>}
        <button onClick={() => onAction("reload")}>重新加载角色资源</button>
        <button onClick={() => onAction("reset")}>恢复默认位置</button>
        <button onClick={() => onAction("hide")}>临时隐藏</button>
        <button className="danger" onClick={() => onAction("quit")}>退出</button>
      </section>
    </div>
  );
}
