import { convertFileSrc, invoke } from "@tauri-apps/api/core";
import { validateManifest } from "./CharacterValidator";
import {
  loadPreparedCharacter,
  prepareLoadedCharacter,
  type PrepareCharacterOptions,
  type PreparedCharacter,
} from "./CharacterLoader";
import type { AnimationDefinition, AnimationState, LoadedAnimation, LoadedCharacter } from "./types";
import { isTauriRuntime } from "../window/windowController";

export type CharacterSource = "bundled" | "local";

let activationGenerationSeed = Date.now();

export function nextActivationGeneration(nowMs = Date.now()): number {
  activationGenerationSeed = Math.max(activationGenerationSeed + 1, Math.floor(nowMs));
  return activationGenerationSeed;
}

export interface CharacterSelectionRequest {
  id: string;
  source?: CharacterSource;
  requestId?: string;
  expiresAtMs?: number;
}

export function isSelectionRequestExpired(
  request: Pick<CharacterSelectionRequest, "expiresAtMs">,
  nowMs = Date.now(),
): boolean {
  return request.expiresAtMs !== undefined && request.expiresAtMs <= nowMs;
}

export interface CharacterSelectionChanged {
  id: string;
  source: CharacterSource;
  requestId?: string;
  ok: boolean;
  error?: string;
}

export interface CharacterCatalogEntry {
  id: string;
  name: string;
  version: string;
  author: string;
  license: string;
  source: CharacterSource;
  valid: boolean;
  errors: string[];
  previewUrl?: string;
  iconUrl?: string;
  manifestPath?: string;
}

interface BundledIndexEntry {
  id: string;
  name?: string;
  version?: string;
  author?: string;
  license?: string;
  manifest?: string;
  preview?: string | null;
  icon?: string | null;
}

interface LocalCharacterSummary {
  id: string;
  name: string;
  version: string;
  author: string;
  license: string;
  source?: "local";
  valid: boolean;
  errors: string[];
  previewPath?: string | null;
  iconPath?: string | null;
}

export interface InstalledCharacterPayload {
  manifest: unknown;
  frames: Record<string, string[]>;
  previewPath?: string | null;
  iconPath?: string | null;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function manifestUrlFor(entry: BundledIndexEntry): string {
  return entry.manifest?.trim() || `/characters/${entry.id}/manifest.json`;
}

function resolveBundledAsset(manifestUrl: string, asset: string | null | undefined): string | undefined {
  if (!asset) return undefined;
  if (asset.startsWith("/") || /^[a-z]+:/i.test(asset)) return asset;
  const slash = manifestUrl.lastIndexOf("/");
  return `${slash >= 0 ? manifestUrl.slice(0, slash + 1) : "/"}${asset}`;
}

function parseBundledIndex(input: unknown): BundledIndexEntry[] {
  const candidate = Array.isArray(input)
    ? input
    : input && typeof input === "object" && Array.isArray((input as { characters?: unknown }).characters)
      ? (input as { characters: unknown[] }).characters
      : [];
  return candidate.flatMap((item): BundledIndexEntry[] => {
    if (typeof item === "string") return [{ id: item }];
    if (!item || typeof item !== "object") return [];
    const entry = item as Partial<BundledIndexEntry>;
    return typeof entry.id === "string" && entry.id.length > 0 ? [{ ...entry, id: entry.id }] : [];
  });
}

async function listBundledCharacters(signal?: AbortSignal): Promise<CharacterCatalogEntry[]> {
  const response = await fetch("/characters/index.json", { cache: "no-store", signal });
  if (!response.ok) throw new Error(`无法读取内置角色索引 (${response.status})`);
  const entries = parseBundledIndex(await response.json());
  return Promise.all(entries.map(async (entry): Promise<CharacterCatalogEntry> => {
    const manifestPath = manifestUrlFor(entry);
    try {
      const manifestResponse = await fetch(manifestPath, { cache: "no-store", signal });
      if (!manifestResponse.ok) throw new Error(`manifest HTTP ${manifestResponse.status}`);
      const validation = validateManifest(await manifestResponse.json());
      if (!validation.valid || !validation.manifest) throw new Error(validation.errors.join("; "));
      const manifest = validation.manifest;
      return {
        id: entry.id,
        name: entry.name ?? manifest.name,
        version: entry.version ?? manifest.version,
        author: entry.author ?? manifest.author,
        license: entry.license ?? manifest.license,
        source: "bundled",
        valid: manifest.id === entry.id,
        errors: manifest.id === entry.id ? [] : [`索引 ID ${entry.id} 与 manifest ID ${manifest.id} 不一致`],
        previewUrl: resolveBundledAsset(manifestPath, entry.preview ?? manifest.preview),
        iconUrl: resolveBundledAsset(manifestPath, entry.icon ?? manifest.icon),
        manifestPath,
      };
    } catch (error) {
      return {
        id: entry.id,
        name: entry.name ?? entry.id,
        version: entry.version ?? "未知",
        author: entry.author ?? "未知",
        license: entry.license ?? "未知",
        source: "bundled",
        valid: false,
        errors: [errorMessage(error)],
        previewUrl: resolveBundledAsset(manifestPath, entry.preview),
        iconUrl: resolveBundledAsset(manifestPath, entry.icon),
        manifestPath,
      };
    }
  }));
}

export function toLocalAssetUrl(
  path: string | null | undefined,
  converter: (path: string) => string = convertFileSrc,
  revision?: string | number,
): string | undefined {
  if (!path?.trim()) return undefined;
  const converted = converter(path);
  if (revision === undefined || revision === "") return converted;
  return `${converted}${converted.includes("?") ? "&" : "?"}qipetRevision=${encodeURIComponent(String(revision))}`;
}

function normalizeLocalSummary(summary: LocalCharacterSummary): CharacterCatalogEntry {
  return {
    id: summary.id,
    name: summary.name,
    version: summary.version,
    author: summary.author,
    license: summary.license,
    source: "local",
    valid: Boolean(summary.valid),
    errors: Array.isArray(summary.errors) ? summary.errors : [],
    previewUrl: toLocalAssetUrl(summary.previewPath, convertFileSrc, summary.version),
    iconUrl: toLocalAssetUrl(summary.iconPath, convertFileSrc, summary.version),
  };
}

export function mergeCharacterCatalog(
  bundled: readonly CharacterCatalogEntry[],
  local: readonly CharacterCatalogEntry[],
): CharacterCatalogEntry[] {
  const bundledIds = new Set(bundled.map((entry) => entry.id));
  const locals = local.map((entry) => bundledIds.has(entry.id)
    ? { ...entry, valid: false, errors: [...entry.errors, "角色 ID 与内置角色冲突，请重新打包后导入"] }
    : entry);
  return [...bundled, ...locals].sort((left, right) => {
    if (left.source !== right.source) return left.source === "bundled" ? -1 : 1;
    return left.name.localeCompare(right.name, "zh-CN");
  });
}

export async function loadCharacterCatalog(signal?: AbortSignal): Promise<CharacterCatalogEntry[]> {
  const bundled = await listBundledCharacters(signal);
  if (!isTauriRuntime()) return bundled;
  const local = await invoke<LocalCharacterSummary[]>("list_installed_characters");
  return mergeCharacterCatalog(bundled, local.map(normalizeLocalSummary));
}

export async function importCharacterPackage(): Promise<CharacterCatalogEntry | null> {
  const imported = await invoke<LocalCharacterSummary | null>("import_character_package");
  return imported ? normalizeLocalSummary(imported) : null;
}

export async function removeInstalledCharacter(id: string): Promise<void> {
  await invoke("remove_installed_character", { id });
}

export function createInstalledCharacter(
  selection: CharacterSelectionRequest,
  payload: InstalledCharacterPayload,
  converter: (path: string) => string = convertFileSrc,
  generation?: number,
): LoadedCharacter {
  const validation = validateManifest(payload.manifest);
  if (!validation.valid || !validation.manifest) throw new Error(validation.errors.join("; "));
  if (validation.manifest.id !== selection.id) {
    throw new Error(`请求角色 ${selection.id} 与本地 manifest ID ${validation.manifest.id} 不一致`);
  }
  const animations: Partial<Record<AnimationState, LoadedAnimation>> = {};
  const warnings = [...validation.warnings];
  const assetRevision = `${validation.manifest.version}:${generation ?? 0}`;
  for (const [state, definition] of Object.entries(validation.manifest.animations) as [AnimationState, AnimationDefinition][]) {
    const nativeFrames = payload.frames?.[state];
    const frames = Array.isArray(nativeFrames)
      ? nativeFrames
        .filter((path): path is string => typeof path === "string" && path.trim().length > 0)
        .map((path) => toLocalAssetUrl(path, converter, assetRevision)!)
      : [];
    if (frames.length === 0) {
      warnings.push(`${state}: 本地角色包没有可用帧，已禁用该动作`);
      continue;
    }
    animations[state] = { ...definition, state, frames };
  }
  if (!animations.idle) throw new Error("idle 动画没有可用帧");
  return {
    manifest: validation.manifest,
    animations: animations as LoadedCharacter["animations"],
    baseUrl: `local-character://${selection.id}`,
    warnings,
  };
}

export async function prepareCatalogCharacter(
  selection: CharacterSelectionRequest,
  options: PrepareCharacterOptions = {},
): Promise<PreparedCharacter> {
  if (selection.source !== "local") {
    return loadPreparedCharacter(selection.id, { ...options, fallbackToPlaceholder: false });
  }
  const payload = await invoke<InstalledCharacterPayload>("load_installed_character", { id: selection.id });
  return prepareLoadedCharacter(createInstalledCharacter(selection, payload, convertFileSrc, options.generation), options);
}

export interface CharacterTransactionResult<T> {
  ok: boolean;
  value: T;
  error?: string;
}

/** Keeps the previous value intact unless the candidate preparation fully succeeds. */
export async function prepareCharacterTransaction<T>(previous: T, prepare: () => Promise<T>): Promise<CharacterTransactionResult<T>> {
  try {
    return { ok: true, value: await prepare() };
  } catch (error) {
    return { ok: false, value: previous, error: errorMessage(error) };
  }
}
