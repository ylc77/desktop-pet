import { validateManifest } from "./CharacterValidator";
import type { AnimationState, LoadedAnimation, LoadedCharacter } from "./types";
import { log } from "../diagnostics/logger";

interface CharacterIndexEntry { id: string; name: string; manifest: string }
interface CharacterIndex { generatedAt: string; characters: CharacterIndexEntry[] }
interface FrameIndex { animations: Record<string, string[]> }
export interface PreparedCharacter { character: LoadedCharacter; loadedFrameCount: number; failedFrames: string[] }

const PLACEHOLDER_ID = "_placeholder";

async function fetchJson(url: string): Promise<unknown> {
  const response = await fetch(url, { cache: "no-store" });
  if (!response.ok) throw new Error(`${response.status} ${response.statusText}: ${url}`);
  return response.json();
}

export async function listCharacters(): Promise<CharacterIndexEntry[]> {
  try {
    const index = (await fetchJson("/characters/index.json")) as CharacterIndex;
    return Array.isArray(index.characters) ? index.characters : [];
  } catch (error) {
    log("error", "无法读取角色索引", error);
    return [{ id: PLACEHOLDER_ID, name: "Placeholder", manifest: `/characters/${PLACEHOLDER_ID}/manifest.json` }];
  }
}

async function loadCharacterUnchecked(id: string): Promise<LoadedCharacter> {
  if (!/^[a-z0-9_][a-z0-9_-]*$/.test(id)) throw new Error(`角色 ID 无效: ${id}`);
  const baseUrl = `/characters/${id}`;
  const [manifestInput, frameInput] = await Promise.all([
    fetchJson(`${baseUrl}/manifest.json`),
    fetchJson(`${baseUrl}/frames.json`),
  ]);
  const validation = validateManifest(manifestInput);
  if (!validation.valid || !validation.manifest) throw new Error(validation.errors.join("; "));
  if (validation.manifest.id !== id) throw new Error(`目录 ID ${id} 与 manifest ID ${validation.manifest.id} 不一致`);
  const frameIndex = frameInput as FrameIndex;
  const animations: Partial<Record<AnimationState, LoadedAnimation>> = {};

  for (const [state, definition] of Object.entries(validation.manifest.animations) as [AnimationState, LoadedCharacter["manifest"]["animations"][AnimationState]][]) {
    if (!definition) continue;
    const frames = frameIndex.animations?.[state] ?? [];
    if (frames.length === 0) {
      validation.warnings.push(`${state}: 没有可用帧，运行时将回退到 idle`);
      continue;
    }
    const safeFrames = frames.filter((path) => typeof path === "string" && !path.startsWith("/") && !path.includes("..") && path.toLowerCase().endsWith(".png"));
    if (safeFrames.length !== frames.length) validation.warnings.push(`${state}: frames.json 包含非法帧路径，已忽略`);
    animations[state] = { ...definition, state, frames: safeFrames.map((path) => `${baseUrl}/${path}`) };
  }
  if (!animations.idle) throw new Error("idle 动画没有可用帧");
  return { manifest: validation.manifest, animations: animations as LoadedCharacter["animations"], baseUrl, warnings: validation.warnings };
}

async function preloadSources(character: LoadedCharacter): Promise<{ loaded: Set<string>; failed: string[] }> {
  const sources = [...new Set(Object.values(character.animations).flatMap((animation) => animation?.frames ?? []))];
  const loaded = new Set<string>();
  const failed: string[] = [];
  await Promise.all(sources.map((src) => new Promise<void>((resolve) => {
    const image = new Image();
    image.onload = () => { loaded.add(src); resolve(); };
    image.onerror = () => { failed.push(src); resolve(); };
    image.src = src;
  })));
  if (failed.length) log("warn", `${failed.length} 个角色帧加载失败`);
  return { loaded, failed };
}

export function keepLoadedFrames(character: LoadedCharacter, loaded: ReadonlySet<string>): LoadedCharacter {
  const animations: Partial<Record<AnimationState, LoadedAnimation>> = {};
  const warnings = [...character.warnings];
  for (const [state, animation] of Object.entries(character.animations)) {
    if (!animation) continue;
    const frames = animation.frames.filter((frame) => loaded.has(frame));
    if (frames.length === 0) {
      warnings.push(`${state}: 所有帧均无法加载，已禁用该动作`);
      continue;
    }
    if (frames.length !== animation.frames.length) warnings.push(`${state}: ${animation.frames.length - frames.length} 个损坏帧已从播放列表移除`);
    animations[state] = { ...animation, frames };
  }
  if (!animations.idle) throw new Error("idle 动画的所有图片均无法加载");
  return { ...character, animations: animations as LoadedCharacter["animations"], warnings };
}

async function prepareUnchecked(id: string): Promise<PreparedCharacter> {
  const character = await loadCharacterUnchecked(id);
  const preload = await preloadSources(character);
  return { character: keepLoadedFrames(character, preload.loaded), loadedFrameCount: preload.loaded.size, failedFrames: preload.failed };
}

export async function loadPreparedCharacter(id: string): Promise<PreparedCharacter> {
  try {
    const prepared = await prepareUnchecked(id);
    log("info", `已加载并验证角色 ${prepared.character.manifest.id}`);
    return prepared;
  } catch (error) {
    log("error", `角色 ${id} 无法安全播放，回退到占位角色`, error);
    if (id === PLACEHOLDER_ID) throw error;
    return prepareUnchecked(PLACEHOLDER_ID);
  }
}
