import { useCallback, useEffect, useRef, useState } from "react";
import { enable as enableAutostart, disable as disableAutostart } from "@tauri-apps/plugin-autostart";
import { listen } from "@tauri-apps/api/event";
import { currentMonitor, getCurrentWindow, PhysicalPosition } from "@tauri-apps/api/window";
import { invoke } from "@tauri-apps/api/core";
import { PetCanvas } from "../components/PetCanvas/PetCanvas";
import { ContextMenu } from "../components/ContextMenu/ContextMenu";
import { DeveloperPanel } from "../components/DeveloperPanel/DeveloperPanel";
import { SettingsPanel } from "../components/SettingsPanel/SettingsPanel";
import { listCharacters, loadPreparedCharacter } from "../core/character/CharacterLoader";
import type { AnimationState, LoadedCharacter } from "../core/character/types";
import { validateManifest } from "../core/character/CharacterValidator";
import { DEFAULT_SETTINGS, DEVELOPER_TOOLS_ALLOWED, type AppSettings } from "../core/settings/settingsSchema";
import { loadSettings, parseSettings, saveSettings } from "../core/settings/settingsStore";
import { closeApp, hideWindow, isTauriRuntime, restoreWindowPosition, saveWindowPosition, setAlwaysOnTop } from "../core/window/windowController";
import { log } from "../core/diagnostics/logger";
import { useAnimationPlayer } from "../hooks/useAnimationPlayer";
import { usePetMotion } from "../hooks/usePetMotion";

interface CharacterOption { id: string; name: string }
interface FrameLoadDiagnostics { status: string; loaded: number; failed: number; generation: number }

export default function App() {
  const [settings, setSettings] = useState<AppSettings>(DEFAULT_SETTINGS);
  const [character, setCharacter] = useState<LoadedCharacter | null>(null);
  const [characters, setCharacters] = useState<CharacterOption[]>([]);
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null);
  const [cacheCount, setCacheCount] = useState(0);
  const [frameLoad, setFrameLoad] = useState({ status: "loading", loaded: 0, failed: 0, generation: 0 });
  const [reloadKey, setReloadKey] = useState(0);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [ready, setReady] = useState(false);
  const [windowVisible, setWindowVisible] = useState(true);
  const previousCharacterId = useRef<string | null>(null);
  const preparedRelease = useRef<(() => void) | null>(null);

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
    void listCharacters().then((items) => setCharacters(items.map(({ id, name }) => ({ id, name }))));
  }, [ready, reloadKey]);

  useEffect(() => {
    if (!ready) return;
    let active = true;
    const controller = new AbortController();
    setFrameLoad({ status: "loading", loaded: 0, failed: 0, generation: reloadKey });
    void loadPreparedCharacter(settings.characterId, { signal: controller.signal, generation: reloadKey }).then((prepared) => {
      if (!active) { prepared.release(); return; }
      preparedRelease.current?.();
      preparedRelease.current = prepared.release;
      const loaded = prepared.character;
      setCharacter(loaded);
      setCacheCount(prepared.cacheCount);
      setFrameLoad({ status: "ready", loaded: prepared.loadedFrameCount, failed: prepared.failedFrames.length, generation: reloadKey });
      setSettings((current) => {
        const characterChanged = previousCharacterId.current !== null && previousCharacterId.current !== loaded.manifest.id;
        const firstLaunch = previousCharacterId.current === null && current.position === null && current.scale === DEFAULT_SETTINGS.scale;
        return {
          ...current,
          characterId: loaded.manifest.id,
          scale: characterChanged || firstLaunch ? loaded.manifest.defaultScale : current.scale,
        };
      });
      previousCharacterId.current = loaded.manifest.id;
    }).catch((error) => {
      if (!controller.signal.aborted) {
        setFrameLoad({ status: "failed", loaded: 0, failed: 1, generation: reloadKey });
        log("error", "占位角色也无法加载", error);
      }
    });
    return () => { active = false; controller.abort(); };
  }, [ready, settings.characterId, reloadKey]);

  useEffect(() => () => preparedRelease.current?.(), []);

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
      if (action === "character") setSettingsOpen(true);
      if (action === "settings") { setSettingsOpen(true); setSettings((current) => ({ ...current, developerPanel: false })); }
      if (action === "developer" && DEVELOPER_TOOLS_ALLOWED) { setSettingsOpen(false); setSettings((current) => ({ ...current, developerPanel: !current.developerPanel })); }
      if (action === "reload") setReloadKey((value) => value + 1);
    }));
    register(listen<{ visible: boolean }>("pet-visibility-changed", (event) => setWindowVisible(event.payload.visible)));
    return () => {
      disposed = true;
      if (positionTimer !== null) window.clearTimeout(positionTimer);
      unlisteners.forEach((fn) => fn());
    };
  }, [ready]);

  const patchSettings = useCallback((patch: Partial<AppSettings>) => setSettings((current) => ({ ...current, ...patch })), []);

  if (!ready || !character) return <div className="loading">正在加载占位角色…</div>;
  return <RunningApp
    character={character}
    settings={settings}
    characters={characters}
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
  />;
}

interface RunningProps {
  character: LoadedCharacter;
  settings: AppSettings;
  characters: CharacterOption[];
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
}

function RunningApp({ character, settings, characters, menu, cacheCount, frameLoad, windowVisible, onWindowVisible, onPatch, onMenu, onReload, settingsOpen, onSettingsOpen }: RunningProps) {
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

  const action = async (name: "reload" | "reset" | "hide" | "quit" | "settings" | "developer") => {
    onMenu(null);
    if (name === "reload") onReload();
    if (name === "settings") { onPatch({ developerPanel: false }); onSettingsOpen(true); }
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
      {menu && <ContextMenu position={menu} settings={settings} characters={characters} developerToolsAllowed={DEVELOPER_TOOLS_ALLOWED} onPatch={onPatch} onAction={(name) => void action(name).catch((error) => log("warn", "菜单操作失败", error))} onClose={() => onMenu(null)} />}
      {settingsOpen && <SettingsPanel character={character} settings={settings} onPatch={onPatch} onClose={() => onSettingsOpen(false)} />}
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
