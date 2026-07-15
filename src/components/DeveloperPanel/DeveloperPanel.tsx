import { useEffect, useState } from "react";
import type { AnimationState, LoadedCharacter } from "../../core/character/types";
import type { StateSnapshot } from "../../core/animation/AnimationStateMachine";
import { getLogs, subscribeLogs, type LogEntry } from "../../core/diagnostics/logger";

interface Props {
  character: LoadedCharacter;
  snapshot: StateSnapshot;
  frameIndex: number;
  fps: number;
  priority: number;
  cacheCount: number;
  paused: boolean;
  showBounds: boolean;
  warnings: readonly string[];
  onTrigger: (state: AnimationState) => void;
  onTogglePaused: () => void;
  onToggleBounds: () => void;
  onReload: () => void;
  onValidate: () => void;
  onSimulateMissingFrame: () => void;
  onSimulateCorruptSettings: () => void;
  onClose: () => void;
}

export function DeveloperPanel({ character, snapshot, frameIndex, fps, priority, cacheCount, paused, showBounds, warnings, onTrigger, onTogglePaused, onToggleBounds, onReload, onValidate, onSimulateMissingFrame, onSimulateCorruptSettings, onClose }: Props) {
  const [logs, setLogs] = useState<readonly LogEntry[]>(getLogs());
  useEffect(() => subscribeLogs(setLogs), []);
  return (
    <aside className="developer-panel">
      <header><strong>开发者面板</strong><button onClick={onClose}>×</button></header>
      <dl>
        <dt>角色</dt><dd>{character.manifest.id}</dd>
        <dt>状态</dt><dd>{snapshot.state}</dd>
        <dt>帧</dt><dd>{frameIndex}</dd>
        <dt>FPS</dt><dd>{fps}</dd>
        <dt>优先级</dt><dd>{priority}</dd>
        <dt>缓存</dt><dd>{cacheCount} 帧</dd>
        <dt>资源路径</dt><dd>{character.baseUrl}</dd>
        <dt>切换原因</dt><dd>{snapshot.reason}</dd>
      </dl>
      <div className="trigger-grid">{Object.keys(character.animations).map((state) => <button key={state} onClick={() => onTrigger(state as AnimationState)}>{state}</button>)}</div>
      <div className="debug-actions">
        <button onClick={onTogglePaused}>{paused ? "继续动画" : "暂停动画"}</button>
        <button onClick={onReload}>重新加载角色包</button>
        <button onClick={onValidate}>校验当前角色包</button>
        <button onClick={onToggleBounds}>{showBounds ? "隐藏锚点和点击区域" : "显示锚点和点击区域"}</button>
        <button onClick={onSimulateMissingFrame}>模拟资源缺失</button>
        <button onClick={onSimulateCorruptSettings}>模拟设置损坏</button>
      </div>
      {warnings.length > 0 && <div className="warning-list">{warnings.map((warning) => <p key={warning}>警告：{warning}</p>)}</div>}
      <div className="log-list">{logs.slice(-12).reverse().map((entry) => <p key={`${entry.at}-${entry.message}`} className={`log-${entry.level}`}>{entry.level}: {entry.message}{entry.details ? ` — ${entry.details}` : ""}</p>)}</div>
    </aside>
  );
}
