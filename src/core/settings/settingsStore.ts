import { invoke } from "@tauri-apps/api/core";
import { appSettingsSchema, DEFAULT_SETTINGS, type AppSettings } from "./settingsSchema";
import { log } from "../diagnostics/logger";
import { isTauriRuntime } from "../window/windowController";

const STORE_KEY = "settings";

interface NativeSettingsReadResult {
  value: unknown;
  recovered: boolean;
  backupFile: string | null;
}

function localRead(): unknown {
  try { return JSON.parse(localStorage.getItem(STORE_KEY) ?? "null"); } catch { return null; }
}

export function parseSettings(candidate: unknown): { settings: AppSettings; recovered: boolean } {
  const parsed = appSettingsSchema.safeParse({ ...DEFAULT_SETTINGS, ...(candidate && typeof candidate === "object" ? candidate : {}) });
  return parsed.success ? { settings: parsed.data, recovered: false } : { settings: DEFAULT_SETTINGS, recovered: true };
}

export async function loadSettings(): Promise<AppSettings> {
  let candidate: unknown = localRead();
  if (isTauriRuntime()) {
    try {
      const native = await invoke<NativeSettingsReadResult>("read_settings_file");
      candidate = native.value;
      if (native.recovered) log("warn", `设置文件损坏，已备份为 ${native.backupFile ?? "corrupt backup"}`);
    } catch (error) {
      log("warn", "Tauri 设置存储不可用，使用浏览器本地存储", error);
    }
  }
  const parsed = parseSettings(candidate);
  if (parsed.recovered) {
    if (isTauriRuntime()) {
      try {
        const backup = await invoke<string | null>("quarantine_invalid_settings_file");
        if (backup) log("warn", `无效设置已备份为 ${backup}`);
      } catch (error) {
        log("warn", "无法备份无效设置文件", error);
      }
    }
    log("error", "设置文件无效，已恢复默认值");
    return DEFAULT_SETTINGS;
  }
  return parsed.settings;
}

export async function saveSettings(settings: AppSettings): Promise<void> {
  const valid = appSettingsSchema.parse(settings);
  localStorage.setItem(STORE_KEY, JSON.stringify(valid));
  if (!isTauriRuntime()) return;
  try { await invoke("write_settings_file", { settings: valid }); } catch (error) { log("warn", "保存 Tauri 设置失败，已保存在本地存储", error); }
}

export async function saveSettingsStrict(settings: AppSettings): Promise<void> {
  const valid = appSettingsSchema.parse(settings);
  if (isTauriRuntime()) {
    await invoke("write_settings_file", { settings: valid });
  }
  localStorage.setItem(STORE_KEY, JSON.stringify(valid));
}
