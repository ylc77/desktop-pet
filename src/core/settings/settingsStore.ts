import { LazyStore } from "@tauri-apps/plugin-store";
import { appSettingsSchema, DEFAULT_SETTINGS, type AppSettings } from "./settingsSchema";
import { log } from "../diagnostics/logger";

const STORE_KEY = "settings";
const store = new LazyStore("settings.json", { defaults: {}, autoSave: 300 });

function localRead(): unknown {
  try { return JSON.parse(localStorage.getItem(STORE_KEY) ?? "null"); } catch { return null; }
}

export function parseSettings(candidate: unknown): { settings: AppSettings; recovered: boolean } {
  const parsed = appSettingsSchema.safeParse({ ...DEFAULT_SETTINGS, ...(candidate && typeof candidate === "object" ? candidate : {}) });
  return parsed.success ? { settings: parsed.data, recovered: false } : { settings: DEFAULT_SETTINGS, recovered: true };
}

export async function loadSettings(): Promise<AppSettings> {
  let candidate: unknown = null;
  try { candidate = await store.get(STORE_KEY); } catch (error) {
    candidate = localRead();
    log("warn", "Tauri 设置存储不可用，使用浏览器本地存储", error);
  }
  const parsed = parseSettings(candidate);
  if (parsed.recovered) {
    log("error", "设置文件无效，已恢复默认值");
    return DEFAULT_SETTINGS;
  }
  return parsed.settings;
}

export async function saveSettings(settings: AppSettings): Promise<void> {
  const valid = appSettingsSchema.parse(settings);
  localStorage.setItem(STORE_KEY, JSON.stringify(valid));
  try { await store.set(STORE_KEY, valid); } catch (error) { log("warn", "保存 Tauri 设置失败，已保存在本地存储", error); }
}
