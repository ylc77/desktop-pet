import type { AppSettings } from "../settings/settingsSchema";
import type { UpdaterSnapshot } from "../updater/updaterTypes";

export const SETTINGS_WINDOW_LABEL = "settings";
export const MAIN_WINDOW_LABEL = "main";

export const desktopControlEvents = {
  ready: "settings-window-ready",
  request: "desktop-control-request",
  snapshot: "desktop-control-snapshot",
  result: "desktop-control-result",
  navigate: "settings-navigate",
} as const;

export type SettingsSectionId = "general" | "appearance" | "behavior" | "update" | "about";

export type DesktopControlAction =
  | "patch-settings"
  | "reset-settings"
  | "check-updates"
  | "open-appearance"
  | "open-log-directory"
  | "export-diagnostics"
  | "update-now"
  | "update-later"
  | "update-skip"
  | "update-retry";

const desktopControlActions = new Set<DesktopControlAction>([
  "patch-settings", "reset-settings", "check-updates", "open-appearance",
  "open-log-directory", "export-diagnostics", "update-now", "update-later",
  "update-skip", "update-retry",
]);

export interface DesktopCharacterSummary {
  id: string;
  name: string;
  version: string;
  author: string;
}

/**
 * A serializable, deliberately small view of the main window state. The main
 * window remains the only owner of settings, updater, and character state.
 */
export interface DesktopControlSnapshot {
  settings: AppSettings;
  updater: UpdaterSnapshot;
  character: DesktopCharacterSummary | null;
  revision: number;
}

export interface SettingsWindowReadyPayload {
  protocolVersion: 1;
}

export interface DesktopControlRequest {
  requestId: string;
  action: DesktopControlAction;
  payload?: unknown;
}

export interface DesktopControlPublicError {
  code: string;
  message: string;
}

export interface DesktopControlResult {
  requestId: string;
  action: DesktopControlAction;
  ok: boolean;
  snapshot?: DesktopControlSnapshot;
  error?: DesktopControlPublicError;
}

export interface SettingsNavigatePayload {
  section: SettingsSectionId;
}

export function isSettingsSectionId(value: unknown): value is SettingsSectionId {
  return value === "general" || value === "appearance" || value === "behavior" || value === "update" || value === "about";
}

export function isDesktopControlResult(value: unknown): value is DesktopControlResult {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<DesktopControlResult>;
  return typeof candidate.requestId === "string"
    && typeof candidate.action === "string"
    && typeof candidate.ok === "boolean";
}

export function isDesktopControlRequest(value: unknown): value is DesktopControlRequest {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<DesktopControlRequest>;
  return typeof candidate.requestId === "string"
    && candidate.requestId.length > 0
    && typeof candidate.action === "string"
    && desktopControlActions.has(candidate.action as DesktopControlAction);
}
