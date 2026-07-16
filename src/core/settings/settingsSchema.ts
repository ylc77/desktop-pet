import { z } from "zod";

export const appSettingsSchema = z.object({
  position: z.object({ x: z.number(), y: z.number() }).nullable(),
  monitorName: z.string().nullable(),
  scale: z.number().min(0.1).max(4),
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
});

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
};
