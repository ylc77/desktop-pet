import { PhysicalPosition, getCurrentWindow } from "@tauri-apps/api/window";
import { log } from "../diagnostics/logger";
import { invoke } from "@tauri-apps/api/core";

export function isTauriRuntime(): boolean { return "__TAURI_INTERNALS__" in window; }

export async function setAlwaysOnTop(value: boolean): Promise<void> {
  if (!isTauriRuntime()) return;
  await getCurrentWindow().setAlwaysOnTop(value);
}

export async function saveWindowPosition(): Promise<{ x: number; y: number } | null> {
  if (!isTauriRuntime()) return null;
  const position = await getCurrentWindow().outerPosition();
  return { x: position.x, y: position.y };
}

export async function restoreWindowPosition(position: { x: number; y: number } | null): Promise<void> {
  if (!isTauriRuntime() || !position) return;
  try { await getCurrentWindow().setPosition(new PhysicalPosition(position.x, position.y)); }
  catch (error) { log("warn", "恢复窗口位置失败，将使用系统默认位置", error); }
}

export async function startDragging(): Promise<void> {
  if (isTauriRuntime()) await getCurrentWindow().startDragging();
}

export async function hideWindow(): Promise<void> { if (isTauriRuntime()) await getCurrentWindow().hide(); }
export async function closeApp(): Promise<void> { if (isTauriRuntime()) await invoke("quit_app"); }
