import type { SettingsSectionId } from "../../core/desktopControl";

const items: { id: SettingsSectionId; label: string }[] = [
  { id: "general", label: "常规" },
  { id: "appearance", label: "外观" },
  { id: "behavior", label: "行为" },
  { id: "update", label: "更新" },
  { id: "about", label: "关于与支持" },
];

interface Props {
  current: SettingsSectionId;
  onNavigate: (section: SettingsSectionId, focusContent: boolean) => void;
}

export function SettingsNavigation({ current, onNavigate }: Props) {
  return (
    <nav className="settings-navigation" aria-label="设置分类">
      {items.map((item) => (
        <button
          key={item.id}
          type="button"
          aria-current={current === item.id ? "page" : undefined}
          onClick={(event) => onNavigate(item.id, event.detail === 0)}
        >
          {item.label}
        </button>
      ))}
    </nav>
  );
}
