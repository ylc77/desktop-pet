import { useId, type ReactNode } from "react";

interface Props {
  label: string;
  description?: string;
  children: (ids: { labelId: string; descriptionId?: string }) => ReactNode;
}

export function SettingsRow({ label, description, children }: Props) {
  const labelId = useId();
  const descriptionId = useId();
  return (
    <div className="settings-row">
      <div>
        <div id={labelId} className="settings-row-label">{label}</div>
        {description && <div id={descriptionId} className="settings-row-description">{description}</div>}
      </div>
      <div className="settings-row-control">{children({ labelId, descriptionId: description ? descriptionId : undefined })}</div>
    </div>
  );
}
