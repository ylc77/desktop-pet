import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties, type KeyboardEvent } from "react";
import type { AppSettings } from "../../core/settings/settingsSchema";
import arrowSyncIcon from "../../assets/menu-icons/arrow-sync-20-regular.svg";
import checkmarkIcon from "../../assets/menu-icons/checkmark-16-regular.svg";
import eyeOffIcon from "../../assets/menu-icons/eye-off-20-regular.svg";
import pauseIcon from "../../assets/menu-icons/pause-20-regular.svg";
import playIcon from "../../assets/menu-icons/play-20-regular.svg";
import powerIcon from "../../assets/menu-icons/power-20-regular.svg";
import settingsIcon from "../../assets/menu-icons/settings-20-regular.svg";
import signOutIcon from "../../assets/menu-icons/sign-out-20-regular.svg";
import sparkleIcon from "../../assets/menu-icons/sparkle-20-regular.svg";

export type PetContextMenuAction = "hide" | "quit" | "settings" | "appearance" | "check-updates";

interface Props {
  position: { x: number; y: number };
  settings: AppSettings;
  updateBusy: boolean;
  onPatch: (patch: Partial<AppSettings>) => void;
  onAction: (action: PetContextMenuAction) => void;
  onClose: () => void;
}

type IconStyle = CSSProperties & { "--menu-icon-url": string };

const VIEWPORT_PADDING = 8;

function MenuIcon({ source, className = "" }: { source: string; className?: string }) {
  return (
    <span
      aria-hidden="true"
      className={`context-menu__icon ${className}`.trim()}
      style={{ "--menu-icon-url": `url("${source}")` } as IconStyle}
    />
  );
}

export function ContextMenu({ position, settings, updateBusy, onPatch, onAction, onClose }: Props) {
  const menuRef = useRef<HTMLElement>(null);
  const [resolvedPosition, setResolvedPosition] = useState(position);
  const [keyboardNavigation, setKeyboardNavigation] = useState(false);

  useLayoutEffect(() => {
    const menu = menuRef.current;
    if (!menu) return;
    const rect = menu.getBoundingClientRect();
    const openOnRight = position.x <= window.innerWidth / 2;
    const preferredX = openOnRight
      ? window.innerWidth - rect.width - VIEWPORT_PADDING
      : VIEWPORT_PADDING;
    setResolvedPosition({
      x: Math.max(VIEWPORT_PADDING, Math.min(preferredX, window.innerWidth - rect.width - VIEWPORT_PADDING)),
      y: Math.max(VIEWPORT_PADDING, Math.min(position.y, window.innerHeight - rect.height - VIEWPORT_PADDING)),
    });
  }, [position]);

  useEffect(() => {
    menuRef.current?.querySelector<HTMLButtonElement>("button:not(:disabled)")?.focus();
  }, []);

  useEffect(() => {
    const closeOnWindowBlur = () => onClose();
    window.addEventListener("blur", closeOnWindowBlur);
    return () => window.removeEventListener("blur", closeOnWindowBlur);
  }, [onClose]);

  const activate = (action: PetContextMenuAction) => {
    onClose();
    onAction(action);
  };

  const patch = (next: Partial<AppSettings>) => {
    onClose();
    onPatch(next);
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    if (event.key === "Escape") {
      event.preventDefault();
      onClose();
      return;
    }
    if (!["ArrowDown", "ArrowUp", "Home", "End", "Tab"].includes(event.key)) return;
    setKeyboardNavigation(true);
    const items = Array.from(menuRef.current?.querySelectorAll<HTMLButtonElement>("button:not(:disabled)") ?? []);
    if (items.length === 0) return;
    event.preventDefault();
    const currentIndex = Math.max(0, items.indexOf(document.activeElement as HTMLButtonElement));
    const nextIndex = event.key === "Home"
      ? 0
      : event.key === "End"
        ? items.length - 1
        : event.key === "ArrowUp" || (event.key === "Tab" && event.shiftKey)
          ? (currentIndex - 1 + items.length) % items.length
          : (currentIndex + 1) % items.length;
    items[nextIndex]?.focus();
  };

  return (
    <div
      className="menu-backdrop"
      onPointerDown={(event) => { if (event.target === event.currentTarget) onClose(); }}
      onContextMenu={(event) => event.preventDefault()}
    >
      <section
        ref={menuRef}
        aria-label="桌宠快捷菜单"
        className={`context-menu${keyboardNavigation ? " context-menu--keyboard" : ""}`}
        role="menu"
        style={{ left: resolvedPosition.x, top: resolvedPosition.y }}
        onKeyDown={handleKeyDown}
        onPointerDown={(event) => event.stopPropagation()}
      >
        <button
          type="button"
          role="menuitemcheckbox"
          aria-checked={settings.animationsPaused}
          onClick={() => patch({ animationsPaused: !settings.animationsPaused })}
        >
          <MenuIcon source={settings.animationsPaused ? playIcon : pauseIcon} />
          <span>{settings.animationsPaused ? "继续动画" : "暂停动画"}</span>
          {settings.animationsPaused && <MenuIcon source={checkmarkIcon} className="context-menu__check" />}
        </button>
        <button type="button" role="menuitem" onClick={() => activate("hide")}>
          <MenuIcon source={eyeOffIcon} />
          <span>隐藏桌宠</span>
        </button>

        <div className="context-menu__separator" role="separator" />

        <button type="button" role="menuitem" onClick={() => activate("appearance")}>
          <MenuIcon source={sparkleIcon} />
          <span>外观中心</span>
        </button>
        <button type="button" role="menuitem" onClick={() => activate("settings")}>
          <MenuIcon source={settingsIcon} />
          <span>设置</span>
        </button>

        <div className="context-menu__separator" role="separator" />

        <button
          type="button"
          role="menuitemcheckbox"
          aria-checked={settings.autostart}
          onClick={() => patch({ autostart: !settings.autostart })}
        >
          <MenuIcon source={powerIcon} />
          <span>开机启动</span>
          {settings.autostart && <MenuIcon source={checkmarkIcon} className="context-menu__check" />}
        </button>
        <button type="button" role="menuitem" disabled={updateBusy} onClick={() => activate("check-updates")}>
          <MenuIcon source={arrowSyncIcon} />
          <span>{updateBusy ? "更新正在进行" : "检查更新"}</span>
        </button>

        <div className="context-menu__separator" role="separator" />

        <button
          type="button"
          role="menuitem"
          className="danger"
          disabled={updateBusy}
          onClick={() => activate("quit")}
        >
          <MenuIcon source={signOutIcon} />
          <span>{updateBusy ? "更新安装中，暂不可退出" : "退出"}</span>
        </button>
      </section>
    </div>
  );
}
