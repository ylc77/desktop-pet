import type { AppSettings } from "../settings/settingsSchema";

export type SelectionPersistenceResult =
  | { ok: true }
  | { ok: false; phase: "persist" | "superseded" | "rollback"; error: unknown };

interface SelectionPersistenceOptions {
  previous: AppSettings;
  next: AppSettings;
  persist: (settings: AppSettings) => Promise<void>;
  isCurrent: () => boolean;
  canRollback: () => boolean;
  activate: () => void;
}

/** Persist the selected character before activation so consumers can trust an `ok` selection event. */
export async function persistSelectionBeforeActivation({
  previous,
  next,
  persist,
  isCurrent,
  canRollback,
  activate,
}: SelectionPersistenceOptions): Promise<SelectionPersistenceResult> {
  if (!isCurrent()) {
    return { ok: false, phase: "superseded", error: new Error("角色切换已被取消") };
  }

  try {
    await persist(next);
  } catch (error) {
    if (canRollback()) {
      try {
        await persist(previous);
      } catch (rollbackError) {
        return { ok: false, phase: "rollback", error: rollbackError };
      }
    }
    return { ok: false, phase: "persist", error };
  }

  if (!isCurrent()) {
    if (canRollback()) {
      try {
        await persist(previous);
      } catch (error) {
        return { ok: false, phase: "rollback", error };
      }
    }
    return { ok: false, phase: "superseded", error: new Error("角色切换已被取消") };
  }

  activate();
  return { ok: true };
}
