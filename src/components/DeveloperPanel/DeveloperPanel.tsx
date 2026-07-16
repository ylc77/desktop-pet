import { useEffect, useState } from "react";
import type { AnimationState, CharacterManifest, LoadedAnimation, LoadedCharacter } from "../../core/character/types";
import type { StateSnapshot, TransitionDiagnostic } from "../../core/animation/AnimationStateMachine";
import type { AnimationDiagnostics } from "../../hooks/useAnimationPlayer";
import type { MotionDiagnostics } from "../../hooks/usePetMotion";
import { getLogs, subscribeLogs, type LogEntry } from "../../core/diagnostics/logger";

interface Props {
  character: LoadedCharacter;
  snapshot: StateSnapshot;
  animation: LoadedAnimation;
  frameIndex: number;
  cacheCount: number;
  frameLoad: { status: string; loaded: number; failed: number; generation: number };
  diagnostics: AnimationDiagnostics;
  motion: MotionDiagnostics;
  display: { monitor: string | null; dpiScale: number };
  input: { event: string; latencyMs: number };
  scale: number;
  anchor: CharacterManifest["anchor"];
  hitbox?: CharacterManifest["hitbox"];
  paused: boolean;
  playbackRate: number;
  ambientEnabled: boolean;
  randomSeed: number | null;
  forceLoop: boolean;
  showBounds: boolean;
  warnings: readonly string[];
  transitions: readonly TransitionDiagnostic[];
  onTrigger: (state: AnimationState) => void;
  onTogglePaused: () => void;
  onStepFrame: () => void;
  onPlaybackRate: (rate: number) => void;
  onAmbientEnabled: (enabled: boolean) => void;
  onRandomSeed: (seed: number | null) => void;
  onToggleForceLoop: () => void;
  onToggleBounds: () => void;
  onReload: () => void;
  onValidate: () => void;
  onSimulateMissingFrame: () => void;
  onSimulateCorruptSettings: () => void;
  onClose: () => void;
}

export function DeveloperPanel({ character, snapshot, animation, frameIndex, cacheCount, frameLoad, diagnostics, motion, display, input, scale, anchor, hitbox, paused, playbackRate, ambientEnabled, randomSeed, forceLoop, showBounds, warnings, transitions, onTrigger, onTogglePaused, onStepFrame, onPlaybackRate, onAmbientEnabled, onRandomSeed, onToggleForceLoop, onToggleBounds, onReload, onValidate, onSimulateMissingFrame, onSimulateCorruptSettings, onClose }: Props) {
  const [logs, setLogs] = useState<readonly LogEntry[]>(getLogs());
  useEffect(() => subscribeLogs(setLogs), []);
  return (
    <aside className="developer-panel">
      <header><strong>开发者面板</strong><button onClick={onClose}>×</button></header>
      <dl>
        <dt>角色</dt><dd>{character.manifest.id}</dd>
        <dt>当前状态</dt><dd>{snapshot.state}</dd>
        <dt>上一状态</dt><dd>{snapshot.previousState ?? "—"}</dd>
        <dt>下一候选</dt><dd>{snapshot.nextCandidate ?? diagnostics.nextAmbient ?? "—"}</dd>
        <dt>优先级</dt><dd>{snapshot.priority}</dd>
        <dt>切换原因</dt><dd>{snapshot.reason}{snapshot.forced ? "（强制）" : ""}</dd>
        <dt>帧</dt><dd>{frameIndex + 1} / {animation.frames.length}</dd>
        <dt>目标 FPS</dt><dd>{animation.fps}</dd>
        <dt>实际更新</dt><dd>{diagnostics.actualFrameUpdates} FPS</dd>
        <dt>rAF</dt><dd>{diagnostics.rafFrequency} Hz</dd>
        <dt>丢弃/限幅</dt><dd>{diagnostics.droppedFrames} / {diagnostics.cappedTicks}</dd>
        <dt>播放状态</dt><dd>{diagnostics.suspended ? "暂停/隐藏" : "运行"} · {playbackRate}x</dd>
        <dt>图片状态</dt><dd>{frameLoad.status} · loaded={frameLoad.loaded} failed={frameLoad.failed}</dd>
        <dt>缓存</dt><dd>{cacheCount} 帧 · 估算 {((cacheCount * character.manifest.frameSize.width * character.manifest.frameSize.height * 4) / 1024 / 1024).toFixed(1)} MiB · generation={frameLoad.generation}</dd>
        <dt>资源路径</dt><dd>{character.baseUrl}</dd>
        <dt>锚点</dt><dd>{anchor.x.toFixed(3)}, {anchor.y.toFixed(3)}</dd>
        <dt>Hitbox</dt><dd>{hitbox ? `${hitbox.x}, ${hitbox.y}, ${hitbox.width}, ${hitbox.height}` : "全画布"}</dd>
        <dt>缩放</dt><dd>{scale.toFixed(2)}</dd>
        <dt>显示器</dt><dd>{display.monitor ?? motion.monitor ?? "未知"}</dd>
        <dt>DPI</dt><dd>{(display.dpiScale || motion.dpiScale).toFixed(2)}x</dd>
        <dt>移动</dt><dd>{motion.active ? `${motion.speed.toFixed(1)} DIP/s` : "静止"}</dd>
        <dt>最近输入</dt><dd>{input.event} · {input.latencyMs.toFixed(1)} ms</dd>
        <dt>动画队列</dt><dd>{diagnostics.queue.join(" → ") || "空"}</dd>
        <dt>随机历史</dt><dd>{diagnostics.recentAmbient.join(" → ") || "空"}</dd>
      </dl>
      <div className="trigger-grid">{Object.keys(character.animations).map((state) => <button key={state} onClick={() => onTrigger(state as AnimationState)}>{state}</button>)}</div>
      <div className="debug-speed-controls">
        {[0.25, 0.5, 1].map((rate) => <button className={playbackRate === rate ? "selected" : ""} key={rate} onClick={() => onPlaybackRate(rate)}>{rate}x</button>)}
        <button onClick={onStepFrame} disabled={!paused}>前进一帧</button>
      </div>
      <div className="debug-actions">
        <button onClick={onTogglePaused}>{paused ? "继续动画" : "暂停动画"}</button>
        <button className={forceLoop ? "selected" : ""} onClick={onToggleForceLoop}>{forceLoop ? "停止强制循环" : "循环当前动作"}</button>
        <button onClick={() => onAmbientEnabled(!ambientEnabled)}>{ambientEnabled ? "禁用随机行为" : "启用随机行为"}</button>
        <button onClick={() => onRandomSeed(randomSeed === null ? 12345 : null)}>{randomSeed === null ? "固定随机种子" : `清除种子 ${randomSeed}`}</button>
        <button onClick={onReload}>重新加载角色包</button>
        <button onClick={onValidate}>校验当前角色包</button>
        <button onClick={onToggleBounds}>{showBounds ? "隐藏调试边界" : "显示锚点/Hitbox/画布"}</button>
        <button onClick={onSimulateMissingFrame}>模拟资源缺失</button>
        <button onClick={onSimulateCorruptSettings}>模拟设置损坏</button>
      </div>
      {transitions.length > 0 && <div className="transition-list">{transitions.slice(-6).reverse().map((transition, index) => <p key={`${transition.requested}-${index}`}>{transition.accepted ? "✓" : "×"} {transition.current} → {transition.requested} · {transition.rejectedBy ?? transition.reason}{transition.forced ? " · forced" : ""}</p>)}</div>}
      {warnings.length > 0 && <div className="warning-list">{warnings.map((warning) => <p key={warning}>警告：{warning}</p>)}</div>}
      <div className="log-list">{logs.slice(-12).reverse().map((entry) => <p key={`${entry.at}-${entry.message}`} className={`log-${entry.level}`}>{entry.level}: {entry.message}{entry.details ? ` — ${entry.details}` : ""}</p>)}</div>
    </aside>
  );
}
