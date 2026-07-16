import { useCallback, useEffect, useRef, useState } from "react";
import { enable as enableAutostart, disable as disableAutostart } from "@tauri-apps/plugin-autostart";
import { emitTo, listen } from "@tauri-apps/api/event";
import { currentMonitor, getCurrentWindow, PhysicalPosition } from "@tauri-apps/api/window";
import { invoke } from "@tauri-apps/api/core";
import { PetCanvas } from "../components/PetCanvas/PetCanvas";
import { ContextMenu } from "../components/ContextMenu/ContextMenu";
import { DeveloperPanel } from "../components/DeveloperPanel/DeveloperPanel";
import { SettingsPanel } from "../components/SettingsPanel/SettingsPanel";
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
import { DEFAULT_SETTINGS, DEVELOPER_TOOLS_ALLOWED, type AppSettings } from "../core/settings/settingsSchema";
import { loadSettings, parseSettings, saveSettings } from "../core/settings/settingsStore";
import { closeApp, hideWindow, isTauriRuntime, restoreWindowPosition, saveWindowPosition, setAlwaysOnTop } from "../core/window/windowController";
import { log } from "../core/diagnostics/logger";
import { useAnimationPlayer } from "../hooks/useAnimationPlayer";
import { usePetMotion } from "../hooks/usePetMotion";

interface FrameLoadDiagnostics { status: string; loaded: number; failed: number; generation: number }
const SELECTION_PREPARE_TIMEOUT_MS = 110_000;
let nativeActivationSequence = 0;

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
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null);
  const [cacheCount, setCacheCount] = useState(0);
  const [frameLoad, setFrameLoad] = useState({ status: "loading", loaded: 0, failed: 0, generation: 0 });
  const [reloadKey, setReloadKey] = useState(0);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [ready, setReady] = useState(false);
  const [windowVisible, setWindowVisible] = useState(true);
  const [appearanceFeedback, setAppearanceFeedback] = useState<string | null>(null);
  const previousCharacterId = useRef<string | null>(null);
  const preparedRelease = useRef<(() => void) | null>(null);
  const selectionController = useRef<AbortController | null>(null);
  const selectionGeneration = useRef(0);

  const activatePrepared = useCallback((prepared: PreparedCharacter, persistSelection: boolean) => {
    preparedRelease.current?.();
    preparedRelease.current = prepared.release;
    const loaded = prepared.character;
    setCharacter(loaded);
    setCacheCount(prepared.cacheCount);
    setFrameLoad({ status: "ready", loaded: prepared.loadedFrameCount, failed: prepared.failedFrames.length, generation: selectionGeneration.current });
    setSettings((current) => {
      const characterChanged = previousCharacterId.current !== null && previousCharacterId.current !== loaded.manifest.id;
      const firstLaunch = previousCharacterId.current === null && current.position === null && current.scale === DEFAULT_SETTINGS.scale;
      return {
        ...current,
        characterId: persistSelection ? loaded.manifest.id : current.characterId,
        skinId: persistSelection ? "default" : current.skinId,
        scale: characterChanged || firstLaunch ? loaded.manifest.defaultScale : current.scale,
      };
    });
    previousCharacterId.current = loaded.manifest.id;
  }, []);

  const notifySelectionChanged = useCallback(async (change: CharacterSelectionChanged) => {
    if (!isTauriRuntime()) return;
    try { await emitTo("appearance", "character-selection-changed", change); }
    catch (error) { log("warn", "发送角色切换结果失败", error); }
  }, []);

  const performSelection = useCallback(async (request: CharacterSelectionRequest) => {
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
    if (controller.signal.aborted || generation !== selectionGeneration.current || deadlineExpired) {
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
    if (controller.signal.aborted || generation !== selectionGeneration.current || authorizationExpired) {
      transaction.value.release();
      await cancelNativeCharacterSelection(request.requestId);
      await notifySelectionChanged({ ...selection, ok: false, error: authorizationExpired ? "角色资源验证超时，切换已取消" : "切换已取消" });
      return;
    }
    activatePrepared(transaction.value, true);
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
  }, [activatePrepared, catalog, notifySelectionChanged]);

  useEffect(() => {
    void (async () => {
      let loaded = DEFAULT_SETTINGS;
      try {
        loaded = await loadSettings();
        setSettings({ ...loaded, developerPanel: DEVELOPER_TOOLS_ALLOWED && loaded.developerPanel });
        await setAlwaysOnTop(loaded.alwaysOnTop);
        await restoreWindowPosition(loaded.position);
      } catch (error) {
        log("error", "原生窗口初始化失败，已使用安全默认界面继续启动", error);
      } finally {
        setReady(true);
      }
    })();
  }, []);

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
        if (!active || controller.signal.aborted || generation !== selectionGeneration.current) {
          prepared.release();
          await cancelNativeCharacterSelection(requestId);
          return false;
        }
        activatePrepared(prepared, false);
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
      const entry = loadedCatalog.find((candidate) => candidate.id === settings.characterId);
      const selection: CharacterSelectionRequest = { id: settings.characterId, source: entry?.source ?? "bundled" };
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
  }, [activatePrepared, ready, reloadKey]);

  useEffect(() => () => preparedRelease.current?.(), []);

  useEffect(() => {
    if (!appearanceFeedback) return;
    const timer = window.setTimeout(() => setAppearanceFeedback(null), 6_000);
    return () => window.clearTimeout(timer);
  }, [appearanceFeedback]);

  useEffect(() => {
    if (!ready) return;
    const timer = window.setTimeout(() => void saveSettings(settings).catch((error) => log("warn", "保存设置失败", error)), 250);
    return () => window.clearTimeout(timer);
  }, [settings, ready]);

  useEffect(() => {
    if (!ready) return;
    void setAlwaysOnTop(settings.alwaysOnTop).catch((error) => log("warn", "修改置顶状态失败", error));
  }, [settings.alwaysOnTop, ready]);

  useEffect(() => {
    if (!ready || !isTauriRuntime()) return;
    void invoke("set_fullscreen_auto_hide", { enabled: settings.hideInFullscreen }).catch((error) => log("warn", "修改全屏自动隐藏失败", error));
  }, [settings.hideInFullscreen, ready]);

  useEffect(() => {
    if (!ready || !isTauriRuntime()) return;
    void (settings.autostart ? enableAutostart() : disableAutostart()).catch((error) => log("warn", "修改开机启动失败", error));
  }, [settings.autostart, ready]);

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
        if (position) setSettings((current) => ({ ...current, position }));
      }).catch((error) => log("warn", "保存窗口位置失败", error)), 180);
    }));
    register(listen<string>("tray-action", (event) => {
      const action = event.payload;
      if (action === "toggle-pause") setSettings((current) => ({ ...current, animationsPaused: !current.animationsPaused }));
      if (action === "toggle-top") setSettings((current) => ({ ...current, alwaysOnTop: !current.alwaysOnTop }));
      if (action === "toggle-autostart") setSettings((current) => ({ ...current, autostart: !current.autostart }));
      if (action === "smaller") setSettings((current) => ({ ...current, scale: Math.max(0.1, current.scale - 0.1) }));
      if (action === "larger") setSettings((current) => ({ ...current, scale: Math.min(4, current.scale + 0.1) }));
      if (action === "opacity-half") setSettings((current) => ({ ...current, opacity: 0.5 }));
      if (action === "opacity-full") setSettings((current) => ({ ...current, opacity: 1 }));
      if (action === "character") void invoke("show_appearance_window").catch((error) => log("warn", "打开外观中心失败", error));
      if (action === "settings") { setSettingsOpen(true); setSettings((current) => ({ ...current, developerPanel: false })); }
      if (action === "developer" && DEVELOPER_TOOLS_ALLOWED) { setSettingsOpen(false); setSettings((current) => ({ ...current, developerPanel: !current.developerPanel })); }
      if (action === "reload") setReloadKey((value) => value + 1);
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
  }, [performSelection, ready]);

  const patchSettings = useCallback((patch: Partial<AppSettings>) => setSettings((current) => ({ ...current, ...patch })), []);

  if (!ready || !character) return <div className="loading">正在加载占位角色…</div>;
  return <RunningApp
    character={character}
    settings={settings}
    menu={menu}
    cacheCount={cacheCount}
    frameLoad={frameLoad}
    windowVisible={windowVisible}
    onWindowVisible={setWindowVisible}
    onPatch={patchSettings}
    onMenu={setMenu}
    onReload={() => setReloadKey((value) => value + 1)}
    settingsOpen={settingsOpen}
    onSettingsOpen={setSettingsOpen}
    appearanceFeedback={appearanceFeedback}
  />;
}

interface RunningProps {
  character: LoadedCharacter;
  settings: AppSettings;
  menu: { x: number; y: number } | null;
  cacheCount: number;
  frameLoad: FrameLoadDiagnostics;
  windowVisible: boolean;
  onWindowVisible: (visible: boolean) => void;
  onPatch: (patch: Partial<AppSettings>) => void;
  onMenu: (menu: { x: number; y: number } | null) => void;
  onReload: () => void;
  settingsOpen: boolean;
  onSettingsOpen: (open: boolean) => void;
  appearanceFeedback: string | null;
}

function RunningApp({ character, settings, menu, cacheCount, frameLoad, windowVisible, onWindowVisible, onPatch, onMenu, onReload, settingsOpen, onSettingsOpen, appearanceFeedback }: RunningProps) {
  const [showDebugBounds, setShowDebugBounds] = useState(false);
  const [simulateMissingFrame, setSimulateMissingFrame] = useState(false);
  const [playbackRate, setPlaybackRate] = useState(1);
  const [ambientEnabled, setAmbientEnabled] = useState(true);
  const [randomSeed, setRandomSeed] = useState<number | null>(null);
  const [forceLoop, setForceLoop] = useState(false);
  const [inputDiagnostic, setInputDiagnostic] = useState({ event: "none", latencyMs: 0 });
  const [displayDiagnostic, setDisplayDiagnostic] = useState({ monitor: null as string | null, dpiScale: window.devicePixelRatio || 1 });
  const { machine, snapshot, animation, frameIndex, frame, diagnostics, stepFrame } = useAnimationPlayer(character, {
    paused: settings.animationsPaused,
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
  const motion = usePetMotion(animation, settings.facing, settings.animationsPaused || !windowVisible, onMotionFacing);

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

  const action = async (name: "reload" | "reset" | "hide" | "quit" | "settings" | "developer" | "appearance") => {
    onMenu(null);
    if (name === "reload") onReload();
    if (name === "settings") { onPatch({ developerPanel: false }); onSettingsOpen(true); }
    if (name === "appearance" && isTauriRuntime()) await invoke("show_appearance_window");
    if (name === "developer" && DEVELOPER_TOOLS_ALLOWED) { onSettingsOpen(false); onPatch({ developerPanel: true }); }
    if (name === "hide") {
      onWindowVisible(false);
      try {
        await hideWindow();
      } catch (error) {
        onWindowVisible(true);
        log("warn", "隐藏窗口失败，已恢复动画运行状态", error);
      }
    }
    if (name === "quit") await closeApp();
    if (name === "reset" && isTauriRuntime()) {
      await getCurrentWindow().setPosition(new PhysicalPosition(40, 40));
      onPatch({ position: { x: 40, y: 40 } });
    }
  };

  return (
    <>
      <PetCanvas frame={frame} animation={animation} settings={settings} frameSize={character.manifest.frameSize} anchor={character.manifest.anchor} hitbox={character.manifest.hitbox} visual={character.manifest.visual} characterName={character.manifest.name} interactions={character.manifest.interactions} showDebugBounds={showDebugBounds} simulateMissingFrame={simulateMissingFrame} onState={transition} onInputDiagnostic={(event, latencyMs) => setInputDiagnostic({ event, latencyMs })} onContextMenu={onMenu} onFrameError={() => { setSimulateMissingFrame(false); log("warn", "检测到无法显示的动画帧，保留上一有效帧并回退到 idle"); transition("idle", "frame-error", true); }} />
      {menu && <ContextMenu position={menu} settings={settings} developerToolsAllowed={DEVELOPER_TOOLS_ALLOWED} onPatch={onPatch} onAction={(name) => void action(name).catch((error) => log("warn", "菜单操作失败", error))} onClose={() => onMenu(null)} />}
      {appearanceFeedback && <div className="pet-notice" role="status">{appearanceFeedback}</div>}
      {settingsOpen && <SettingsPanel settings={settings} onPatch={onPatch} onClose={() => onSettingsOpen(false)} />}
      {DEVELOPER_TOOLS_ALLOWED && settings.developerPanel && <DeveloperPanel
        character={character} snapshot={snapshot} animation={animation} frameIndex={frameIndex} cacheCount={cacheCount}
        frameLoad={frameLoad} diagnostics={diagnostics} motion={motion} display={displayDiagnostic} input={inputDiagnostic}
        scale={settings.scale} anchor={character.manifest.anchor} hitbox={character.manifest.hitbox}
        paused={settings.animationsPaused} playbackRate={playbackRate} ambientEnabled={ambientEnabled} randomSeed={randomSeed} forceLoop={forceLoop} showBounds={showDebugBounds}
        warnings={character.warnings} transitions={machine.recentTransitions}
        onTrigger={(state) => transition(state, "developer", true)} onTogglePaused={() => onPatch({ animationsPaused: !settings.animationsPaused })}
        onStepFrame={stepFrame} onPlaybackRate={setPlaybackRate} onAmbientEnabled={setAmbientEnabled} onRandomSeed={setRandomSeed} onToggleForceLoop={() => setForceLoop((value) => !value)}
        onToggleBounds={() => setShowDebugBounds((value) => !value)} onReload={onReload}
        onValidate={() => { const result = validateManifest(character.manifest); log(result.valid ? "info" : "error", result.valid ? `角色包 ${character.manifest.id} 运行时校验通过` : result.errors.join("; ")); }}
        onSimulateMissingFrame={() => setSimulateMissingFrame(true)} onSimulateCorruptSettings={() => { const result = parseSettings({ scale: "invalid" }); log(result.recovered ? "info" : "error", result.recovered ? "设置损坏模拟通过：已恢复默认值" : "设置损坏模拟未触发回退"); }}
        onClose={() => onPatch({ developerPanel: false })}
      />}
    </>
  );
}
