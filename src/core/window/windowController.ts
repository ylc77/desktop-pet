import { LogicalPosition, PhysicalPosition, getCurrentWindow } from "@tauri-apps/api/window";
import { log } from "../diagnostics/logger";
import { invoke } from "@tauri-apps/api/core";
import type { NormalizedPetInteractionRegion } from "./petInteractionRegion";

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

export interface ManualWindowDragSession {
  pointerStart: { x: number; y: number };
  windowStart: { x: number; y: number };
}

export async function beginManualWindowDrag(pointerStart: { x: number; y: number }): Promise<ManualWindowDragSession | null> {
  if (!isTauriRuntime()) return null;
  const windowHandle = getCurrentWindow();
  const [position, scaleFactor] = await Promise.all([
    windowHandle.outerPosition(),
    windowHandle.scaleFactor(),
  ]);
  const logicalPosition = position.toLogical(scaleFactor);
  return {
    pointerStart,
    windowStart: { x: logicalPosition.x, y: logicalPosition.y },
  };
}

export async function updateManualWindowDrag(
  session: ManualWindowDragSession | null,
  pointer: { x: number; y: number },
): Promise<void> {
  if (!isTauriRuntime() || !session) return;
  await getCurrentWindow().setPosition(new LogicalPosition(
    Math.round(session.windowStart.x + pointer.x - session.pointerStart.x),
    Math.round(session.windowStart.y + pointer.y - session.pointerStart.y),
  ));
}

export async function setPetInteractionRegion(region: NormalizedPetInteractionRegion | null): Promise<void> {
  if (isTauriRuntime()) await invoke("set_pet_interaction_region", { region });
}

export async function hideWindow(): Promise<void> { if (isTauriRuntime()) await getCurrentWindow().hide(); }
export async function closeApp(): Promise<void> { if (isTauriRuntime()) await invoke("quit_app"); }
