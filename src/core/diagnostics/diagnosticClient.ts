import { invoke } from "@tauri-apps/api/core";
import type { LoadedCharacter } from "../character/types";
import type { AppSettings } from "../settings/settingsSchema";
import type { UpdaterSnapshot } from "../updater/updaterTypes";
import { getLogs, sanitizeDiagnosticText } from "./logger";

export interface DiagnosticExportResult {
  fileName: string;
  location: "downloads" | "applicationData";
}

function safeSettingsSummary(settings: AppSettings): Record<string, unknown> {
  return {
    scale: settings.scale,
    opacity: settings.opacity,
    alwaysOnTop: settings.alwaysOnTop,
    autostart: settings.autostart,
    animationsPaused: settings.animationsPaused,
    hideInFullscreen: settings.hideInFullscreen,
    interactionsEnabled: settings.interactionsEnabled,
    automaticUpdateChecks: settings.automaticUpdateChecks,
    updateLastFailureCategory: settings.updateLastFailureCategory,
    pendingUpdateVersion: settings.pendingUpdateVersion,
    lastConfirmedUpdateVersion: settings.lastConfirmedUpdateVersion,
    updateLastFailedVersion: settings.updateLastFailedVersion,
    hasSavedPosition: settings.position !== null,
    facing: settings.facing,
  };
}

export async function openLogDirectory(): Promise<void> {
  await invoke("open_log_directory");
}

export async function exportDiagnostics(
  settings: AppSettings,
  character: LoadedCharacter,
  updater: UpdaterSnapshot,
): Promise<DiagnosticExportResult> {
  const frontendLogs = getLogs().map((entry) => ({
    ...entry,
    message: sanitizeDiagnosticText(entry.message),
    details: entry.details ? sanitizeDiagnosticText(entry.details) : undefined,
  }));
  return invoke<DiagnosticExportResult>("export_diagnostics", {
    request: {
      characterId: character.manifest.id,
      characterVersion: character.manifest.version,
      characterSchemaVersion: character.manifest.schemaVersion,
      settingsSummary: safeSettingsSummary(settings),
      frontendLogs,
      updaterStatus: updater.status,
      updaterFailureCategory: updater.error?.category ?? null,
    },
  });
}
