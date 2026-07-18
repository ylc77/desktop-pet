import { useCallback, useEffect, useRef, useState } from "react";
import { enable as enableAutostart, disable as disableAutostart } from "@tauri-apps/plugin-autostart";
import { emitTo, listen } from "@tauri-apps/api/event";
import { currentMonitor, getCurrentWindow, PhysicalPosition } from "@tauri-apps/api/window";
import { invoke } from "@tauri-apps/api/core";
import { PetCanvas } from "../components/PetCanvas/PetCanvas";
import { DeveloperPanel } from "../components/DeveloperPanel/DeveloperPanel";
import type { PreparedCharacter } from "../core/character/CharacterLoader";
import {
  isSelectionRequestExpired,
  loadCharacterCatalog,
  nextActivationGeneration,
  prepareCatalogCharacter,
  prepareCharacterTransaction,
  type CharacterCatalogEntry,
  type CharacterSelectionChanged,
  type CharacterSelectionRequest,
} from "../core/character/CharacterCatalog";
import type { AnimationState, LoadedCharacter } from "../core/character/types";
import { validateManifest } from "../core/character/CharacterValidator";
import { persistSelectionBeforeActivation } from "../core/character/selectionPersistence";
import { appSettingsSchema, DEFAULT_SETTINGS, DEVELOPER_TOOLS_ALLOWED, resetSettingsPreservingCharacter, type AppSettings } from "../core/settings/settingsSchema";
import { loadSettings, parseSettings, saveSettings, saveSettingsStrict } from "../core/settings/settingsStore";
import { SettingsTransactionQueue } from "../core/settings/settingsTransactionQueue";
import { closeApp, isTauriRuntime, restoreWindowPosition, saveWindowPosition, setAlwaysOnTop } from "../core/window/windowController";
import { exportDiagnostics, openLogDirectory } from "../core/diagnostics/diagnosticClient";
import { log } from "../core/diagnostics/logger";
import { createNativeUpdaterClient } from "../core/updater/nativeUpdaterClient";
import { reconcilePendingUpdate, shouldRunAutomaticCheck, startupCheckDelayMs } from "../core/updater/updaterPolicy";
import { UpdaterStore } from "../core/updater/updaterStore";
import { useAnimationPlayer } from "../hooks/useAnimationPlayer";
import { usePetMotion } from "../hooks/usePetMotion";
import { isRuntimeMotionPaused, usePrefersReducedMotion } from "../hooks/usePrefersReducedMotion";
import {
  DesktopControlActionError,
  MainControlCoordinator,
  type DesktopControlRequest,
  type DesktopControlSnapshot,
  type SettingsSectionId,
} from "../core/desktopControl";

interface FrameLoadDiagnostics { status: string; loaded: number; failed: number; generation: number }
const SELECTION_PREPARE_TIMEOUT_MS = 110_000;
let nativeActivationSequence = 0;

const settingsWindowPatchKeys = new Set<keyof AppSettings>([
  "scale", "opacity", "alwaysOnTop", "autostart", "animationsPaused", "volume",
  "hideInFullscreen", "interactionsEnabled", "facing", "automaticUpdateChecks",
]);

type NativeAppAction = "appearance" | "settings" | "toggle-pause" | "hide" | "show" | "toggle-top" | "toggle-autostart" | "check-updates" | "about" | "reset" | "quit";
type ToggleableSetting = "animationsPaused" | "developerPanel";

interface NativeMenuStatePayload {
  paused: boolean;
  alwaysOnTop: boolean;
  autostart: boolean;
  updateBusy: boolean;
}

function updaterIsBusy(status: string): boolean {
  return status === "downloading" || status === "readyToInstall" || status === "installing" || status === "restarting";
}

function readSettingsPatch(payload: unknown): Partial<AppSettings> {
  if (!payload || typeof payload !== "object" || !("patch" in payload)) {
    throw new DesktopControlActionError("invalid-settings", "这项设置无法识别，请关闭设置窗口后重试。");
  }
  const candidate = (payload as { patch?: unknown }).patch;
  if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) {
    throw new DesktopControlActionError("invalid-settings", "这项设置无法识别，请关闭设置窗口后重试。");
  }
  for (const key of Object.keys(candidate)) {
    if (!settingsWindowPatchKeys.has(key as keyof AppSettings)) {
      throw new DesktopControlActionError("invalid-settings", "这项设置无法识别，请关闭设置窗口后重试。");
    }
  }
  return candidate as Partial<AppSettings>;
}

async function showSettingsWindow(section: SettingsSectionId): Promise<void> {
  if (isTauriRuntime()) {
    await invoke("show_settings_window", { section });
    return;
  }
  const url = new URL(window.location.href);
  url.searchParams.set("surface", "settings");
  url.searchParams.set("section", section);
  window.location.assign(url);
}

function createNativeActivationRequestId(generation: number): string {
  nativeActivationSequence += 1;
  return `main-${generation}-${Date.now().toString(36)}-${nativeActivationSequence.toString(36)}`;
}

async function cancelNativeCharacterSelection(requestId: string | undefined): Promise<void> {
  if (!requestId || !isTauriRuntime()) return;
  try { await invoke("cancel_character_selection", { requestId }); }
  catch (error) { log("warn", "清理原生待处理角色切换失败", error); }
}

async function authorizeNativeCharacterSelection(id: string, requestId: string | undefined, generation: number): Promise<void> {
  if (!isTauriRuntime()) return;
  if (requestId) {
    await invoke("commit_character_selection", { id, requestId, generation });
    return;
  }
  const accepted = await invoke<boolean>("set_active_character_id", { id, generation });
  if (!accepted) throw new Error("角色激活代次已被更新请求取代");
}

async function finalizeNativeCharacterSelection(id: string, requestId: string | undefined, generation: number): Promise<void> {
  if (!isTauriRuntime() || !requestId) return;
  await invoke("finalize_character_selection", { id, requestId, generation });
}

async function beginNativeCharacterActivation(id: string, requestId: string, generation: number): Promise<void> {
  if (!isTauriRuntime()) return;
  await invoke("begin_character_activation", { id, requestId, generation });
}

async function setNativeActiveCharacter(id: string, generation: number): Promise<boolean> {
  if (!isTauriRuntime()) return true;
  return invoke<boolean>("set_active_character_id", { id, generation });
}

export default function App() {
  const [settings, setSettings] = useState<AppSettings>(DEFAULT_SETTINGS);
  const [character, setCharacter] = useState<LoadedCharacter | null>(null);
  const [catalog, setCatalog] = useState<CharacterCatalogEntry[]>([]);
  const [cacheCount, setCacheCount] = useState(0);
  const [frameLoad, setFrameLoad] = useState({ status: "loading", loaded: 0, failed: 0, generation: 0 });
  const [reloadKey, setReloadKey] = useState(0);
  const [updateSuspended, setUpdateSuspended] = useState(false);
  const [updateMenuBusy, setUpdateMenuBusy] = useState(false);
  const [updaterStore] = useState(() => new UpdaterStore(createNativeUpdaterClient()));
  const [ready, setReady] = useState(false);
  const [windowVisible, setWindowVisible] = useState(true);
  const [appearanceFeedback, setAppearanceFeedback] = useState<string | null>(null);
  const [updateResultNotice, setUpdateResultNotice] = useState<string | null>(null);
  const settingsRef = useRef(settings);
  const settingsTransactions = useRef(new SettingsTransactionQueue());
  const characterRef = useRef(character);
  characterRef.current = character;
  const desktopRevision = useRef(0);
  const desktopCoordinator = useRef<MainControlCoordinator | null>(null);
  const previousCharacterId = useRef<string | null>(null);
  const preparedRelease = useRef<(() => void) | null>(null);
  const selectionController = useRef<AbortController | null>(null);
  const selectionGeneration = useRef(0);
  const shuttingDown = useRef(false);

  const runSettingsTransaction = useCallback(function runSettingsTransaction<T>(operation: () => Promise<T>): Promise<T> {
    return settingsTransactions.current.run(operation);
  }, []);

  const replaceSettings = useCallback((update: AppSettings | ((current: AppSettings) => AppSettings)): AppSettings => {
    const next = typeof update === "function" ? update(settingsRef.current) : update;
    settingsRef.current = next;
    setSettings(next);
    return next;
  }, []);

  const queueSettingsStateUpdate = useCallback((update: (current: AppSettings) => AppSettings): Promise<void> => {
    if (shuttingDown.current) return Promise.resolve();
    return runSettingsTransaction(async () => {
      const next = update(settingsRef.current);
      replaceSettings(next);
      await saveSettings(next);
    }).catch((error) => {
      log("warn", "设置已在当前会话生效，但持久化失败", error);
    });
  }, [replaceSettings, runSettingsTransaction]);

  const applyChangedNativeSettings = useCallback(async (next: AppSettings, previous: AppSettings) => {
    if (next.alwaysOnTop !== previous.alwaysOnTop) await setAlwaysOnTop(next.alwaysOnTop);
    if (!isTauriRuntime()) return;
    if (next.hideInFullscreen !== previous.hideInFullscreen) {
      await invoke("set_fullscreen_auto_hide", { enabled: next.hideInFullscreen });
    }
    if (next.autostart !== previous.autostart) {
      await (next.autostart ? enableAutostart() : disableAutostart());
    }
  }, []);

  const commitSettings = useCallback(async (mutate: (current: AppSettings) => AppSettings) => {
    if (shuttingDown.current) return;
    await runSettingsTransaction(async () => {
      const previous = settingsRef.current;
      const next = mutate(previous);
      try {
        await applyChangedNativeSettings(next, previous);
        await saveSettingsStrict(next);
      } catch (error) {
        let rollbackFailed = false;
        try { await applyChangedNativeSettings(previous, next); }
        catch (rollbackError) {
          rollbackFailed = true;
          log("warn", "设置应用失败后的系统状态恢复未全部完成", rollbackError);
        }
        try { await saveSettingsStrict(previous); }
        catch (rollbackError) {
          rollbackFailed = true;
          log("warn", "设置应用失败后无法严格写回原设置", rollbackError);
        }
        log("warn", rollbackFailed ? "设置未能完整应用，原设置也未能完全恢复" : "设置未能完整应用，已保留原设置", error);
        throw new DesktopControlActionError(
          "settings-apply-failed",
          rollbackFailed
            ? "这项设置未能保存，原设置也未能完全恢复。请重启七酱桌宠并查看日志。"
            : "这项设置未能保存，已保留原来的设置。请重试或查看日志。",
        );
      }
      replaceSettings(next);
    });
  }, [applyChangedNativeSettings, replaceSettings, runSettingsTransaction]);

  const flushSettingsAndClose = useCallback(async () => {
    if (shuttingDown.current) return;
    shuttingDown.current = true;
    try {
      await runSettingsTransaction(async () => {
        const current = settingsRef.current;
        let finalSettings = current;
        if (isTauriRuntime()) {
          try {
            const position = await saveWindowPosition();
            if (position) finalSettings = { ...current, position };
          } catch (error) {
            log("warn", "退出前读取最终窗口位置失败，保留最近位置", error);
          }
        }
        replaceSettings(finalSettings);
        try { await saveSettings(finalSettings); }
        catch (error) { log("warn", "退出前保存最终设置失败", error); }
        await closeApp();
      });
    } catch (error) {
      shuttingDown.current = false;
      throw error;
    }
  }, [replaceSettings, runSettingsTransaction]);

  const settingsForActivation = useCallback((loaded: LoadedCharacter, persistSelection: boolean): AppSettings => {
    const current = settingsRef.current;
    const characterChanged = previousCharacterId.current !== null && previousCharacterId.current !== loaded.manifest.id;
    const firstLaunch = previousCharacterId.current === null && current.position === null && current.scale === DEFAULT_SETTINGS.scale;
    return {
      ...current,
      characterId: persistSelection ? loaded.manifest.id : current.characterId,
      skinId: persistSelection ? "default" : current.skinId,
      scale: characterChanged || firstLaunch ? loaded.manifest.defaultScale : current.scale,
    };
  }, []);

  const activatePrepared = useCallback((prepared: PreparedCharacter, persistSelection: boolean, preparedSettings?: AppSettings) => {
    preparedRelease.current?.();
    preparedRelease.current = prepared.release;
    const loaded = prepared.character;
    const nextSettings = preparedSettings ?? settingsForActivation(loaded, persistSelection);
    setCharacter(loaded);
    setCacheCount(prepared.cacheCount);
    setFrameLoad({ status: "ready", loaded: prepared.loadedFrameCount, failed: prepared.failedFrames.length, generation: selectionGeneration.current });
    replaceSettings(nextSettings);
    previousCharacterId.current = loaded.manifest.id;
  }, [replaceSettings, settingsForActivation]);

  const notifySelectionChanged = useCallback(async (change: CharacterSelectionChanged) => {
    if (!isTauriRuntime()) return;
    try { await emitTo("appearance", "character-selection-changed", change); }
    catch (error) { log("warn", "发送角色切换结果失败", error); }
  }, []);

  const performSelection = useCallback(async (request: CharacterSelectionRequest) => {
    if (shuttingDown.current) {
      await cancelNativeCharacterSelection(request.requestId);
      await notifySelectionChanged({ id: request.id, source: request.source ?? "bundled", requestId: request.requestId, ok: false, error: "应用正在退出，角色切换已取消" });
      return;
    }
    if (isSelectionRequestExpired(request)) {
      await cancelNativeCharacterSelection(request.requestId);
      await notifySelectionChanged({ id: request.id, source: request.source ?? "bundled", requestId: request.requestId, ok: false, error: "角色切换请求已过期" });
      return;
    }
    const matching = catalog.find((entry) => entry.id === request.id && (!request.source || entry.source === request.source));
    const localIdCollision = request.source === "local" && catalog.some((entry) => entry.source === "bundled" && entry.id === request.id);
    if (localIdCollision || (matching?.source === "bundled" && !matching.valid)) {
      const error = localIdCollision ? "角色 ID 与内置角色冲突" : matching?.errors.join("; ") || "角色资源校验失败";
      setAppearanceFeedback(`切换失败，已保留当前外观：${error}`);
      await cancelNativeCharacterSelection(request.requestId);
      await notifySelectionChanged({ id: request.id, source: request.source ?? matching?.source ?? "bundled", requestId: request.requestId, ok: false, error });
      return;
    }
    const selection = { id: request.id, source: request.source ?? matching?.source ?? "bundled", requestId: request.requestId, expiresAtMs: request.expiresAtMs } satisfies CharacterSelectionRequest & { source: "bundled" | "local" };
    const generation = nextActivationGeneration();
    selectionGeneration.current = generation;
    selectionController.current?.abort();
    const controller = new AbortController();
    selectionController.current = controller;
    setFrameLoad((current) => ({ ...current, status: "loading", generation }));
    let timedOut = false;
    const remainingMs = request.expiresAtMs === undefined
      ? SELECTION_PREPARE_TIMEOUT_MS
      : Math.max(1, Math.min(SELECTION_PREPARE_TIMEOUT_MS, request.expiresAtMs - Date.now()));
    const prepareTimeout = window.setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, remainingMs);
    const transaction = await prepareCharacterTransaction<PreparedCharacter | null>(null, () => prepareCatalogCharacter(selection, { signal: controller.signal, generation }))
      .finally(() => window.clearTimeout(prepareTimeout));
    const deadlineExpired = isSelectionRequestExpired(request);
    if (deadlineExpired && !controller.signal.aborted) controller.abort();
    if (shuttingDown.current || controller.signal.aborted || generation !== selectionGeneration.current || deadlineExpired) {
      if (transaction.ok) transaction.value?.release();
      await cancelNativeCharacterSelection(request.requestId);
      await notifySelectionChanged({ ...selection, ok: false, error: timedOut || deadlineExpired ? "角色资源验证超时，切换已取消" : "切换已取消" });
      return;
    }
    if (!transaction.ok || !transaction.value) {
      const error = transaction.error ?? "未知错误";
      setFrameLoad((current) => ({ ...current, status: preparedRelease.current ? "ready" : "failed", failed: current.failed + 1, generation }));
      setAppearanceFeedback(`切换失败，已保留当前外观：${error}`);
      log("warn", `角色 ${selection.id} 事务式切换失败，当前角色保持不变`, error);
      await cancelNativeCharacterSelection(request.requestId);
      await notifySelectionChanged({ ...selection, ok: false, error });
      return;
    }
    try {
      await authorizeNativeCharacterSelection(transaction.value.character.manifest.id, request.requestId, generation);
    } catch (error) {
      transaction.value.release();
      await cancelNativeCharacterSelection(request.requestId);
      const message = error instanceof Error ? error.message : String(error);
      setAppearanceFeedback(`切换失败，已保留当前外观：${message}`);
      await notifySelectionChanged({ ...selection, ok: false, error: message });
      return;
    }
    const authorizationExpired = isSelectionRequestExpired(request);
    if (shuttingDown.current || controller.signal.aborted || generation !== selectionGeneration.current || authorizationExpired) {
      transaction.value.release();
      await cancelNativeCharacterSelection(request.requestId);
      await notifySelectionChanged({ ...selection, ok: false, error: authorizationExpired ? "角色资源验证超时，切换已取消" : "切换已取消" });
      return;
    }
    const persistence = await runSettingsTransaction(async () => {
      const previousSettings = settingsRef.current;
      const selectedSettings = settingsForActivation(transaction.value!.character, true);
      return persistSelectionBeforeActivation({
        previous: previousSettings,
        next: selectedSettings,
        persist: saveSettingsStrict,
        isCurrent: () => !shuttingDown.current
          && !controller.signal.aborted
          && generation === selectionGeneration.current
          && !isSelectionRequestExpired(request),
        // This rollback executes while the single settings transaction queue is held,
        // so a newer selection cannot be overwritten by the older request.
        canRollback: () => true,
        activate: () => activatePrepared(transaction.value!, true, selectedSettings),
      });
    });
    if (!persistence.ok) {
      transaction.value.release();
      await cancelNativeCharacterSelection(request.requestId);
      const error = persistence.phase === "persist"
        ? "无法保存角色选择，已保留当前外观"
        : persistence.phase === "rollback"
          ? "角色切换已取消，但无法恢复原设置；请重启应用"
          : shuttingDown.current
            ? "应用正在退出，角色切换已取消"
            : "角色切换已被更新请求取代";
      if (generation === selectionGeneration.current) {
        setFrameLoad((current) => ({ ...current, status: preparedRelease.current ? "ready" : "failed", failed: current.failed + 1, generation }));
        setAppearanceFeedback(error);
      }
      log("warn", `${error}（${String(persistence.error)}）`);
      await notifySelectionChanged({ ...selection, ok: false, error });
      return;
    }
    try {
      await finalizeNativeCharacterSelection(transaction.value.character.manifest.id, request.requestId, generation);
    } catch (error) {
      try {
        const accepted = await setNativeActiveCharacter(transaction.value.character.manifest.id, generation);
        if (!accepted) {
          await cancelNativeCharacterSelection(request.requestId);
          log("warn", "角色切换完成已被更新请求取代，旧请求不会报告成功", error);
          await notifySelectionChanged({ ...selection, ok: false, error: "角色切换已被更新请求取代" });
          return;
        }
      } catch (fallbackError) {
        log("error", "角色已激活，但原生当前角色状态同步失败；已保留 pending 保护并等待持久设置协调", fallbackError);
        await notifySelectionChanged({ ...selection, ok: false, error: "角色已加载，但无法同步原生选择状态，请重启应用" });
        return;
      }
      await cancelNativeCharacterSelection(request.requestId);
      log("warn", "角色完成事件迟到，已按激活代次同步原生当前角色", error);
    }
    setAppearanceFeedback(`已切换为 ${transaction.value.character.manifest.name}`);
    await notifySelectionChanged({ ...selection, ok: true });
  }, [activatePrepared, catalog, notifySelectionChanged, runSettingsTransaction, settingsForActivation]);

  useEffect(() => {
    void (async () => {
      let loaded = DEFAULT_SETTINGS;
      try {
        loaded = await loadSettings();
        replaceSettings({ ...loaded, developerPanel: DEVELOPER_TOOLS_ALLOWED && loaded.developerPanel });
      } catch (error) {
        log("error", "设置初始化失败，已使用安全默认值继续启动", error);
      }
      try { await restoreWindowPosition(loaded.position); }
      catch (error) { log("warn", "恢复窗口位置失败，已使用系统默认位置", error); }
      setReady(true);
    })();
  }, [replaceSettings]);

  useEffect(() => {
    if (!ready) return;
    let active = true;
    const controller = new AbortController();
    const generation = nextActivationGeneration();
    selectionGeneration.current = generation;
    selectionController.current?.abort();
    selectionController.current = controller;
    setFrameLoad({ status: "loading", loaded: 0, failed: 0, generation });
    void (async () => {
      const activateStartupCandidate = async (prepared: PreparedCharacter): Promise<boolean> => {
        const requestId = createNativeActivationRequestId(generation);
        try {
          await beginNativeCharacterActivation(prepared.character.manifest.id, requestId, generation);
        } catch (error) {
          prepared.release();
          throw error;
        }
        if (shuttingDown.current || !active || controller.signal.aborted || generation !== selectionGeneration.current) {
          prepared.release();
          await cancelNativeCharacterSelection(requestId);
          return false;
        }
        const activated = await runSettingsTransaction(async () => {
          if (shuttingDown.current) return false;
          const previousSettings = settingsRef.current;
          const preparedSettings = settingsForActivation(prepared.character, false);
          try { await saveSettings(preparedSettings); }
          catch (error) { log("warn", "启动或重载角色时保存最终缩放失败", error); }
          if (shuttingDown.current || !active || controller.signal.aborted || generation !== selectionGeneration.current) {
            try { await saveSettings(previousSettings); }
            catch (error) { log("warn", "启动角色被取代后无法恢复先前设置", error); }
            return false;
          }
          activatePrepared(prepared, false, preparedSettings);
          return true;
        });
        if (!activated) {
          prepared.release();
          await cancelNativeCharacterSelection(requestId);
          return false;
        }
        try {
          await finalizeNativeCharacterSelection(prepared.character.manifest.id, requestId, generation);
        } catch (error) {
          const accepted = await setNativeActiveCharacter(prepared.character.manifest.id, generation);
          await cancelNativeCharacterSelection(requestId);
          if (!accepted) return true;
          log("warn", "启动或重载角色的两阶段原生状态完成失败，已按激活代次恢复", error);
        }
        return true;
      };
      let loadedCatalog: CharacterCatalogEntry[] = [];
      try {
        loadedCatalog = await loadCharacterCatalog(controller.signal);
        if (!active) return;
        setCatalog(loadedCatalog);
      } catch (error) {
        if (!controller.signal.aborted) log("warn", "角色目录读取失败，将尝试读取当前内置角色", error);
      }
      const selectedCharacterId = settingsRef.current.characterId;
      const entry = loadedCatalog.find((candidate) => candidate.id === selectedCharacterId);
      const selection: CharacterSelectionRequest = { id: selectedCharacterId, source: entry?.source ?? "bundled" };
      try {
        const prepared = await prepareCatalogCharacter(selection, { signal: controller.signal, generation });
        if (!active || controller.signal.aborted) { prepared.release(); return; }
        await activateStartupCandidate(prepared);
      } catch (error) {
        if (controller.signal.aborted) return;
        if (preparedRelease.current) {
          setFrameLoad((current) => ({ ...current, status: "ready", failed: current.failed + 1, generation }));
          setAppearanceFeedback(`重新加载失败，已保留当前外观。请在外观中心检查角色包。`);
          log("warn", `角色 ${settings.characterId} 重新加载失败，当前内存角色保持不变`, error);
          return;
        }
        log("error", `已保存的角色 ${settings.characterId} 无法加载，临时显示占位角色且保留原选择`, error);
        setAppearanceFeedback(`已保存的外观无法加载，当前临时显示占位角色。请在外观中心修复或重新选择。`);
        try {
          const fallback = await prepareCatalogCharacter({ id: "_placeholder", source: "bundled" }, { signal: controller.signal, generation });
          if (!active || controller.signal.aborted) { fallback.release(); return; }
          await activateStartupCandidate(fallback);
        } catch (fallbackError) {
          if (!controller.signal.aborted) {
            setFrameLoad({ status: "failed", loaded: 0, failed: 1, generation });
            log("error", "占位角色也无法加载", fallbackError);
          }
        }
      }
    })();
    return () => { active = false; controller.abort(); };
  }, [activatePrepared, ready, reloadKey, runSettingsTransaction, settingsForActivation]);

  useEffect(() => () => preparedRelease.current?.(), []);

  useEffect(() => {
    if (!appearanceFeedback) return;
    const timer = window.setTimeout(() => setAppearanceFeedback(null), 6_000);
    return () => window.clearTimeout(timer);
  }, [appearanceFeedback]);

  useEffect(() => {
    if (!updateResultNotice) return;
    const timer = window.setTimeout(() => setUpdateResultNotice(null), 8_000);
    return () => window.clearTimeout(timer);
  }, [updateResultNotice]);

  useEffect(() => {
    if (!ready) return;
    void runSettingsTransaction(async () => {
      const current = settingsRef.current;
      try { await setAlwaysOnTop(current.alwaysOnTop); }
      catch (error) { log("warn", "应用启动时恢复置顶状态失败", error); }
      if (!isTauriRuntime()) return;
      try { await invoke("set_fullscreen_auto_hide", { enabled: current.hideInFullscreen }); }
      catch (error) { log("warn", "应用启动时恢复全屏自动隐藏状态失败", error); }
      try { await (current.autostart ? enableAutostart() : disableAutostart()); }
      catch (error) { log("warn", "应用启动时恢复开机启动状态失败", error); }
    });
  }, [ready, runSettingsTransaction]);

  useEffect(() => {
    if (!ready || !isTauriRuntime()) return;
    const state: NativeMenuStatePayload = {
      paused: settings.animationsPaused,
      alwaysOnTop: settings.alwaysOnTop,
      autostart: settings.autostart,
      updateBusy: updateMenuBusy,
    };
    void invoke("sync_native_menu_state", { state }).catch((error) => log("warn", "同步原生菜单状态失败", error));
  }, [ready, settings.animationsPaused, settings.alwaysOnTop, settings.autostart, updateMenuBusy]);

  useEffect(() => {
    let lastTransition: unknown = null;
    return updaterStore.subscribe(() => {
      const snapshot = updaterStore.getSnapshot();
      const suspended = snapshot.status === "installing" || snapshot.status === "restarting";
      setUpdateSuspended((current) => current === suspended ? current : suspended);
      const menuBusy = updaterIsBusy(snapshot.status);
      setUpdateMenuBusy((current) => current === menuBusy ? current : menuBusy);
      desktopRevision.current += 1;
      void desktopCoordinator.current?.publishSnapshot().catch((error) => log("warn", "同步设置窗口更新状态失败", error));
      const transition = snapshot.transitions.at(-1);
      if (!transition || transition === lastTransition) return;
      lastTransition = transition;
      if (transition.from === "checking") {
        queueSettingsStateUpdate((current) => ({
          ...current,
          updateLastCheckAt: transition.at,
          updateLastAvailableVersion: snapshot.update?.version ?? null,
        }));
      }
      if (snapshot.status === "error") {
        queueSettingsStateUpdate((current) => ({
          ...current,
          updateLastFailureCategory: snapshot.error?.category ?? "unknown",
        }));
        log("warn", snapshot.reason, snapshot.error?.message);
      } else if (["upToDate", "available", "readyToInstall", "restarting", "postponed", "skipped"].includes(snapshot.status)) {
        queueSettingsStateUpdate((current) => current.updateLastFailureCategory === null ? current : {
          ...current,
          updateLastFailureCategory: null,
        });
      }
    });
  }, [queueSettingsStateUpdate, updaterStore]);

  useEffect(() => {
    if (!ready) return;
    let active = true;
    let timer: number | null = null;
    void updaterStore.initialize().then(() => {
      if (!active) return;
      const configuration = updaterStore.getSnapshot().configuration;
      if (configuration) {
        const result = reconcilePendingUpdate(configuration.currentVersion, settings.pendingUpdateVersion, settings.updateLastFailedVersion);
        if (result.status === "installed") {
          queueSettingsStateUpdate((current) => ({
            ...current,
            pendingUpdateVersion: null,
            lastConfirmedUpdateVersion: result.version,
            updateLastFailedVersion: null,
            updateLastFailureCategory: null,
          }));
          setUpdateResultNotice(`七酱桌宠已成功更新到 ${result.version}。`);
        } else if (result.status === "notInstalled") {
          if (result.notify) {
            log("warn", `更新结果未确认：当前版本 ${result.currentVersion}，目标版本 ${result.targetVersion}`);
            setUpdateResultNotice(`更新未完成：当前仍为 ${result.currentVersion}，目标为 ${result.targetVersion}。可在“关于”中重新检查。`);
          }
          queueSettingsStateUpdate((current) => {
            const failureCategory = current.updateLastFailureCategory === "restartFailed" || current.updateLastFailureCategory === "installFailed"
              ? current.updateLastFailureCategory
              : "installFailed";
            if (current.updateLastFailedVersion === result.targetVersion && current.updateLastFailureCategory === failureCategory) return current;
            return { ...current, updateLastFailedVersion: result.targetVersion, updateLastFailureCategory: failureCategory };
          });
        }
      }
      if (!configuration?.configured || !settings.automaticUpdateChecks || !shouldRunAutomaticCheck(settings.updateLastCheckAt)) return;
      timer = window.setTimeout(() => {
        if (active) void updaterStore.check({ manual: false, skippedVersion: settings.updateSkippedVersion })
          .catch((error) => log("warn", "启动自动检查更新未执行", error));
      }, startupCheckDelayMs());
    }).catch((error) => log("warn", "初始化更新服务失败", error));
    return () => {
      active = false;
      if (timer !== null) window.clearTimeout(timer);
    };
  }, [queueSettingsStateUpdate, ready, settings.automaticUpdateChecks, settings.pendingUpdateVersion, settings.updateLastCheckAt, settings.updateLastFailedVersion, settings.updateSkippedVersion, updaterStore]);

  useEffect(() => {
    if (!isTauriRuntime() || !ready) return;
    const unlisteners: (() => void)[] = [];
    let disposed = false;
    let positionTimer: number | null = null;
    const register = (promise: Promise<() => void>) => void promise
      .then((fn) => { if (disposed) fn(); else unlisteners.push(fn); })
      .catch((error) => log("warn", "注册窗口事件监听失败", error));
    register(getCurrentWindow().onMoved(() => {
      if (positionTimer !== null) window.clearTimeout(positionTimer);
      positionTimer = window.setTimeout(() => void saveWindowPosition().then((position) => {
        if (position) queueSettingsStateUpdate((current) => ({ ...current, position }));
      }).catch((error) => log("warn", "保存窗口位置失败", error)), 180);
    }));
    register(listen<NativeAppAction>("app-action", (event) => {
      const action = event.payload;
      if (action === "toggle-pause") void commitSettings((current) => ({ ...current, animationsPaused: !current.animationsPaused })).catch((error) => log("warn", "切换动画暂停状态失败", error));
      if (action === "toggle-top") void commitSettings((current) => ({ ...current, alwaysOnTop: !current.alwaysOnTop })).catch((error) => log("warn", "切换窗口置顶状态失败", error));
      if (action === "toggle-autostart") void commitSettings((current) => ({ ...current, autostart: !current.autostart })).catch((error) => log("warn", "切换开机启动状态失败", error));
      if (action === "appearance") void invoke("show_appearance_window").catch((error) => log("warn", "打开外观中心失败", error));
      if (action === "settings") void showSettingsWindow("general").catch((error) => log("warn", "打开设置失败", error));
      if (action === "about") void showSettingsWindow("about").catch((error) => log("warn", "打开关于与支持失败", error));
      if (action === "check-updates") {
        void showSettingsWindow("update").catch((error) => log("warn", "打开更新设置失败", error));
        void updaterStore.check({ manual: true }).catch((error) => log("warn", "菜单检查更新未执行", error));
      }
      if (action === "reset") {
        void getCurrentWindow().setPosition(new PhysicalPosition(40, 40))
          .then(() => queueSettingsStateUpdate((current) => ({ ...current, position: { x: 40, y: 40 } })))
          .catch((error) => log("warn", "恢复默认位置失败", error));
      }
      if (action === "hide") setWindowVisible(false);
      if (action === "show") setWindowVisible(true);
      if (action === "quit") void flushSettingsAndClose().catch((error) => log("warn", "退出应用失败", error));
    }));
    register(listen<CharacterSelectionRequest>("character-selection-requested", (event) => {
      void performSelection(event.payload).catch((error) => log("warn", "处理角色切换请求失败", error));
    }));
    register(listen<{ visible: boolean }>("pet-visibility-changed", (event) => setWindowVisible(event.payload.visible)));
    return () => {
      disposed = true;
      if (positionTimer !== null) window.clearTimeout(positionTimer);
      unlisteners.forEach((fn) => fn());
    };
  }, [commitSettings, flushSettingsAndClose, performSelection, queueSettingsStateUpdate, ready, updaterStore]);

  const patchSettings = useCallback((patch: Partial<AppSettings>) => {
    queueSettingsStateUpdate((current) => ({ ...current, ...patch }));
  }, [queueSettingsStateUpdate]);

  const toggleSetting = useCallback((key: ToggleableSetting) => {
    queueSettingsStateUpdate((current) => ({ ...current, [key]: !current[key] }));
  }, [queueSettingsStateUpdate]);

  const installUpdate = useCallback(async () => {
    if (shuttingDown.current) throw new Error("应用正在退出，已取消更新安装");
    await updaterStore.updateNow({
      beforeInstall: async () => {
        await runSettingsTransaction(async () => {
          if (shuttingDown.current) throw new Error("应用正在退出，已取消更新安装");
          const targetVersion = updaterStore.getSnapshot().update?.version ?? null;
          if (!targetVersion) throw new Error("更新目标版本不可用");
          const currentSettings = settingsRef.current;
          const position = isTauriRuntime() ? await saveWindowPosition() : currentSettings.position;
          const prepared = { ...currentSettings, position: position ?? currentSettings.position, pendingUpdateVersion: targetVersion };
          let preparedPersisted = false;
          try {
            await saveSettingsStrict(prepared);
            preparedPersisted = true;
            if (shuttingDown.current) throw new Error("应用正在退出，已取消更新安装");
            replaceSettings(prepared);
            if (isTauriRuntime()) await invoke("flush_application_logs");
            if (shuttingDown.current) throw new Error("应用正在退出，已取消更新安装");
          } catch (error) {
            if (shuttingDown.current) {
              if (preparedPersisted) {
                try { await saveSettingsStrict(currentSettings); }
                catch (rollbackError) { log("warn", "退出期间取消更新后无法恢复先前设置", rollbackError); }
              }
              replaceSettings(currentSettings);
              throw error;
            }
            const cleared = { ...currentSettings, pendingUpdateVersion: null };
            try { await saveSettingsStrict(cleared); }
            catch (rollbackError) { log("warn", "更新准备失败后无法清理待确认版本", rollbackError); }
            replaceSettings(cleared);
            throw error;
          }
        });
      },
    });
  }, [replaceSettings, runSettingsTransaction, updaterStore]);

  const resetSettings = useCallback(async () => {
    await commitSettings((current) => resetSettingsPreservingCharacter(current));
    if (isTauriRuntime()) await invoke("restore_main_window");
  }, [commitSettings]);

  const getDesktopSnapshot = useCallback((): DesktopControlSnapshot => {
    const currentCharacter = characterRef.current;
    return {
      settings: settingsRef.current,
      updater: updaterStore.getSnapshot(),
      character: currentCharacter ? {
        id: currentCharacter.manifest.id,
        name: currentCharacter.manifest.name,
        version: currentCharacter.manifest.version,
        author: currentCharacter.manifest.author,
      } : null,
      revision: desktopRevision.current,
    };
  }, [updaterStore]);

  const handleDesktopControlRequest = useCallback(async (request: DesktopControlRequest) => {
    if (request.action === "patch-settings") {
      const patch = readSettingsPatch(request.payload);
      await commitSettings((current) => appSettingsSchema.parse({ ...current, ...patch }));
      return;
    }
    if (request.action === "reset-settings") {
      await resetSettings();
      return;
    }
    if (request.action === "check-updates") {
      await updaterStore.check({ manual: true });
      return;
    }
    if (request.action === "open-appearance") {
      if (!isTauriRuntime()) throw new DesktopControlActionError("desktop-only", "外观中心需要在七酱桌宠中打开。");
      await invoke("show_appearance_window");
      return;
    }
    if (request.action === "open-log-directory") {
      await openLogDirectory();
      return;
    }
    if (request.action === "export-diagnostics") {
      const currentCharacter = characterRef.current;
      if (!currentCharacter) throw new DesktopControlActionError("character-unavailable", "角色仍在加载，请稍后再导出诊断信息。");
      await exportDiagnostics(settingsRef.current, currentCharacter, updaterStore.getSnapshot());
      return;
    }
    if (request.action === "update-now") {
      await installUpdate();
      return;
    }
    if (request.action === "update-later") {
      await updaterStore.later();
      return;
    }
    if (request.action === "update-skip") {
      const version = updaterStore.getSnapshot().update?.version ?? null;
      if (!version) throw new DesktopControlActionError("update-unavailable", "当前没有可跳过的更新版本。");
      if (await updaterStore.skip()) {
        await commitSettings((current) => appSettingsSchema.parse({ ...current, updateSkippedVersion: version }));
      }
      return;
    }
    if (request.action === "update-retry") {
      await updaterStore.retry();
    }
  }, [commitSettings, installUpdate, resetSettings, updaterStore]);

  useEffect(() => {
    if (!ready || !isTauriRuntime()) return;
    const coordinator = new MainControlCoordinator({
      getSnapshot: getDesktopSnapshot,
      handleRequest: handleDesktopControlRequest,
    });
    desktopCoordinator.current = coordinator;
    let disposed = false;
    void coordinator.start().then(() => {
      if (disposed) coordinator.stop();
      else void coordinator.publishSnapshot().catch((error) => log("warn", "发送设置窗口初始状态失败", error));
    }).catch((error) => log("warn", "启动设置窗口状态桥失败", error));
    return () => {
      disposed = true;
      if (desktopCoordinator.current === coordinator) desktopCoordinator.current = null;
      coordinator.stop();
    };
  }, [getDesktopSnapshot, handleDesktopControlRequest, ready]);

  useEffect(() => {
    if (!ready) return;
    desktopRevision.current += 1;
    void desktopCoordinator.current?.publishSnapshot().catch((error) => log("warn", "同步设置窗口应用状态失败", error));
  }, [character, ready, settings]);

  const showPetContextMenu = useCallback(async (position: { x: number; y: number }) => {
    if (!isTauriRuntime()) return;
    const currentSettings = settingsRef.current;
    const state: NativeMenuStatePayload = {
      paused: currentSettings.animationsPaused,
      alwaysOnTop: currentSettings.alwaysOnTop,
      autostart: currentSettings.autostart,
      updateBusy: updaterIsBusy(updaterStore.getSnapshot().status),
    };
    await invoke("show_pet_context_menu", { x: position.x, y: position.y, state });
  }, [updaterStore]);

  if (!ready || !character) return <div className="loading">正在加载占位角色…</div>;
  return <RunningApp
    character={character}
    settings={settings}
    cacheCount={cacheCount}
    frameLoad={frameLoad}
    windowVisible={windowVisible}
    onPatch={patchSettings}
    onToggleSetting={toggleSetting}
    onContextMenu={(position) => void showPetContextMenu(position).catch((error) => log("warn", "打开原生桌宠菜单失败", error))}
    onReload={() => setReloadKey((value) => value + 1)}
    updateSuspended={updateSuspended}
    appearanceFeedback={appearanceFeedback}
    updateResultNotice={updateResultNotice}
  />;
}

interface RunningProps {
  character: LoadedCharacter;
  settings: AppSettings;
  cacheCount: number;
  frameLoad: FrameLoadDiagnostics;
  windowVisible: boolean;
  onPatch: (patch: Partial<AppSettings>) => void;
  onToggleSetting: (key: ToggleableSetting) => void;
  onContextMenu: (position: { x: number; y: number }) => void;
  onReload: () => void;
  updateSuspended: boolean;
  appearanceFeedback: string | null;
  updateResultNotice: string | null;
}

function RunningApp({ character, settings, cacheCount, frameLoad, windowVisible, onPatch, onToggleSetting, onContextMenu, onReload, updateSuspended, appearanceFeedback, updateResultNotice }: RunningProps) {
  const [showDebugBounds, setShowDebugBounds] = useState(false);
  const [simulateMissingFrame, setSimulateMissingFrame] = useState(false);
  const [playbackRate, setPlaybackRate] = useState(1);
  const [ambientEnabled, setAmbientEnabled] = useState(true);
  const [randomSeed, setRandomSeed] = useState<number | null>(null);
  const [forceLoop, setForceLoop] = useState(false);
  const [inputDiagnostic, setInputDiagnostic] = useState({ event: "none", latencyMs: 0 });
  const [displayDiagnostic, setDisplayDiagnostic] = useState({ monitor: null as string | null, dpiScale: window.devicePixelRatio || 1 });
  const prefersReducedMotion = usePrefersReducedMotion();
  const runtimeMotionPaused = isRuntimeMotionPaused(settings.animationsPaused, prefersReducedMotion);
  const { machine, snapshot, animation, frameIndex, frame, diagnostics, stepFrame } = useAnimationPlayer(character, {
    paused: runtimeMotionPaused || updateSuspended,
    suspended: !windowVisible,
    playbackRate,
    ambientEnabled,
    randomSeed,
    forceLoop,
  });
  const transition = useCallback((state: AnimationState, reason: string, force?: boolean) => machine.transition(state, reason, force), [machine]);
  const onMotionFacing = useCallback((facing: "left" | "right", reverseTo?: string) => {
    onPatch({ facing });
    if (reverseTo) transition(reverseTo, "movement-edge-reverse", true);
  }, [onPatch, transition]);
  const motion = usePetMotion(animation, settings.facing, runtimeMotionPaused || updateSuspended || !windowVisible, onMotionFacing);

  useEffect(() => {
    if (!settings.developerPanel || !isTauriRuntime()) return;
    let active = true;
    const update = () => void currentMonitor()
      .then((monitor) => {
        if (active) setDisplayDiagnostic({ monitor: monitor?.name ?? null, dpiScale: monitor?.scaleFactor ?? window.devicePixelRatio ?? 1 });
      })
      .catch((error) => log("warn", "读取开发诊断显示器信息失败", error));
    update();
    const timer = window.setInterval(update, 1_000);
    return () => { active = false; window.clearInterval(timer); };
  }, [settings.developerPanel]);

  useEffect(() => {
    if (!DEVELOPER_TOOLS_ALLOWED) return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (!event.ctrlKey || !event.shiftKey || event.key.toLowerCase() !== "d") return;
      event.preventDefault();
      onToggleSetting("developerPanel");
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onToggleSetting]);

  return (
    <>
      <PetCanvas frame={frame} animation={animation} settings={settings} frameSize={character.manifest.frameSize} anchor={character.manifest.anchor} hitbox={character.manifest.hitbox} visual={character.manifest.visual} characterName={character.manifest.name} interactions={character.manifest.interactions} showDebugBounds={showDebugBounds} simulateMissingFrame={simulateMissingFrame} onState={transition} onInputDiagnostic={(event, latencyMs) => setInputDiagnostic({ event, latencyMs })} onContextMenu={onContextMenu} onFrameError={() => { setSimulateMissingFrame(false); log("warn", "检测到无法显示的动画帧，保留上一有效帧并回退到 idle"); transition("idle", "frame-error", true); }} />
      {appearanceFeedback && <div className="pet-notice" role="status">{appearanceFeedback}</div>}
      {!appearanceFeedback && updateResultNotice && <div className="pet-notice" role="status">{updateResultNotice}</div>}
      {DEVELOPER_TOOLS_ALLOWED && settings.developerPanel && <DeveloperPanel
        character={character} snapshot={snapshot} animation={animation} frameIndex={frameIndex} cacheCount={cacheCount}
        frameLoad={frameLoad} diagnostics={diagnostics} motion={motion} display={displayDiagnostic} input={inputDiagnostic}
        scale={settings.scale} anchor={character.manifest.anchor} hitbox={character.manifest.hitbox}
        paused={settings.animationsPaused} runtimePaused={runtimeMotionPaused || updateSuspended || !windowVisible} reducedMotion={prefersReducedMotion} playbackRate={playbackRate} ambientEnabled={ambientEnabled} randomSeed={randomSeed} forceLoop={forceLoop} showBounds={showDebugBounds}
        warnings={character.warnings} transitions={machine.recentTransitions}
        onTrigger={(state) => transition(state, "developer", true)} onTogglePaused={() => onToggleSetting("animationsPaused")}
        onStepFrame={stepFrame} onPlaybackRate={setPlaybackRate} onAmbientEnabled={setAmbientEnabled} onRandomSeed={setRandomSeed} onToggleForceLoop={() => setForceLoop((value) => !value)}
        onToggleBounds={() => setShowDebugBounds((value) => !value)} onReload={onReload}
        onValidate={() => { const result = validateManifest(character.manifest); log(result.valid ? "info" : "error", result.valid ? `角色包 ${character.manifest.id} 运行时校验通过` : result.errors.join("; ")); }}
        onSimulateMissingFrame={() => setSimulateMissingFrame(true)} onSimulateCorruptSettings={() => { const result = parseSettings({ scale: "invalid" }); log(result.recovered ? "info" : "error", result.recovered ? "设置损坏模拟通过：已恢复默认值" : "设置损坏模拟未触发回退"); }}
        onClose={() => onPatch({ developerPanel: false })}
      />}
    </>
  );
}
