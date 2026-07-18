import type { ReactNode } from "react";

interface Props {
  title: string;
  description?: string;
  actions?: ReactNode;
  onClose?: () => void;
  closeDisabled?: boolean;
}

export function WindowHeader({ title, description, actions, onClose, closeDisabled = false }: Props) {
  return (
    <header className="window-header">
      <div>
        <h1 id="settings-window-title" tabIndex={-1}>{title}</h1>
        {description && <p>{description}</p>}
      </div>
      <div className="window-header-actions">
        {actions}
        {onClose && <button type="button" className="icon-button" aria-label={`关闭${title}`} disabled={closeDisabled} onClick={onClose}>×</button>}
      </div>
    </header>
  );
}
