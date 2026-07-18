interface Props {
  checked: boolean;
  disabled?: boolean;
  labelledBy: string;
  describedBy?: string;
  onChange: (checked: boolean) => void;
}

export function Toggle({ checked, disabled = false, labelledBy, describedBy, onChange }: Props) {
  return (
    <label className="toggle-control">
      <input
        type="checkbox"
        checked={checked}
        disabled={disabled}
        aria-labelledby={labelledBy}
        aria-describedby={describedBy}
        onChange={(event) => onChange(event.currentTarget.checked)}
      />
      <span className="toggle-visual" aria-hidden="true" />
    </label>
  );
}
