import { z } from "zod";
import { MAX_PERSISTED_PET_SCALE, MIN_PERSISTED_PET_SCALE } from "../animation/petScale";

export const appSettingsSchema = z.object({
  position: z.object({ x: z.number(), y: z.number() }).nullable(),
  monitorName: z.string().nullable(),
  scale: z.number().min(MIN_PERSISTED_PET_SCALE).max(MAX_PERSISTED_PET_SCALE),
  opacity: z.number().min(0.2).max(1),
  characterId: z.string().min(1),
  skinId: z.string().min(1),
  alwaysOnTop: z.boolean(),
  autostart: z.boolean(),
  animationsPaused: z.boolean(),
  volume: z.number().min(0).max(1),
  hideInFullscreen: z.boolean(),
  developerPanel: z.boolean(),
  interactionsEnabled: z.boolean(),
  facing: z.enum(["left", "right"]),
  automaticUpdateChecks: z.boolean(),
  updateLastCheckAt: z.string().nullable(),
  updateLastAvailableVersion: z.string().nullable(),
  updateSkippedVersion: z.string().nullable(),
  updateLastFailureCategory: z.enum([
    "notConfigured", "offline", "timeout", "endpointNotFound", "invalidMetadata",
    "invalidSignature", "downloadInterrupted", "permissionDenied", "installFailed",
    "restartFailed", "unsupported", "busy", "unknown",
  ]).nullable(),
  pendingUpdateVersion: z.string().nullable(),
  lastConfirmedUpdateVersion: z.string().nullable(),
  updateLastFailedVersion: z.string().nullable(),
});
export const appSettingsPatchSchema = appSettingsSchema.partial();

export type AppSettings = z.infer<typeof appSettingsSchema>;
export const DEVELOPER_TOOLS_ALLOWED = import.meta.env.DEV || import.meta.env.VITE_ENABLE_DEVELOPER_TOOLS === "true";

export const DEFAULT_SETTINGS: AppSettings = {
  position: null,
  monitorName: null,
  scale: 1,
  opacity: 1,
  characterId: "_placeholder",
  skinId: "default",
  alwaysOnTop: true,
  autostart: false,
  animationsPaused: false,
  volume: 0.8,
  hideInFullscreen: false,
  developerPanel: import.meta.env.DEV,
  interactionsEnabled: true,
  facing: "right",
  automaticUpdateChecks: true,
  updateLastCheckAt: null,
  updateLastAvailableVersion: null,
  updateSkippedVersion: null,
  updateLastFailureCategory: null,
  pendingUpdateVersion: null,
  lastConfirmedUpdateVersion: null,
  updateLastFailedVersion: null,
};

export function resetSettingsPreservingCharacter(current: AppSettings): AppSettings {
  return {
    ...current,
    position: DEFAULT_SETTINGS.position,
    monitorName: DEFAULT_SETTINGS.monitorName,
    scale: DEFAULT_SETTINGS.scale,
    alwaysOnTop: DEFAULT_SETTINGS.alwaysOnTop,
    animationsPaused: DEFAULT_SETTINGS.animationsPaused,
    hideInFullscreen: DEFAULT_SETTINGS.hideInFullscreen,
    interactionsEnabled: DEFAULT_SETTINGS.interactionsEnabled,
    facing: DEFAULT_SETTINGS.facing,
    automaticUpdateChecks: DEFAULT_SETTINGS.automaticUpdateChecks,
    updateLastCheckAt: DEFAULT_SETTINGS.updateLastCheckAt,
    updateLastAvailableVersion: DEFAULT_SETTINGS.updateLastAvailableVersion,
    updateSkippedVersion: DEFAULT_SETTINGS.updateSkippedVersion,
    updateLastFailureCategory: DEFAULT_SETTINGS.updateLastFailureCategory,
    updateLastFailedVersion: DEFAULT_SETTINGS.updateLastFailedVersion,
  };
}
