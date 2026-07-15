import { useRef } from "react";
import type { AppSettings } from "../../core/settings/settingsSchema";
import type { AnimationState, CharacterManifest, LoadedAnimation } from "../../core/character/types";
import { startDragging } from "../../core/window/windowController";

interface Props {
  frame: string;
  animation: LoadedAnimation;
  settings: AppSettings;
  frameSize: { width: number; height: number };
  anchor: { x: number; y: number };
  hitbox?: CharacterManifest["hitbox"];
  characterName: string;
  interactions?: CharacterManifest["interactions"];
  showDebugBounds: boolean;
  simulateMissingFrame: boolean;
  onState: (state: AnimationState, reason: string, force?: boolean) => void;
  onContextMenu: (position: { x: number; y: number }) => void;
  onFrameError: () => void;
}

const DRAG_THRESHOLD = 6;

export function PetCanvas({ frame, animation, settings, frameSize, anchor, hitbox, characterName, interactions, showDebugBounds, simulateMissingFrame, onState, onContextMenu, onFrameError }: Props) {
  const gesture = useRef<{ x: number; y: number; dragging: boolean } | null>(null);
  const lastInteraction = useRef(0);
  const activeHitbox = hitbox ?? { x: 0, y: 0, width: 1, height: 1 };

  const trigger = (state: AnimationState, reason: string) => {
    if (!settings.interactionsEnabled || Date.now() - lastInteraction.current < (interactions?.cooldownMs ?? 350)) return;
    lastInteraction.current = Date.now();
    onState(state, reason);
  };

  return (
    <main className="pet-stage">
      <div
        className="pet-transform"
        style={{
          width: frameSize.width,
          height: frameSize.height,
          transform: `scale(${settings.scale * (animation.scale ?? 1)}) translate(${animation.offsetX ?? 0}px, ${animation.offsetY ?? 0}px)`,
          transformOrigin: `${anchor.x * 100}% ${anchor.y * 100}%`,
          opacity: settings.opacity,
        }}
      >
        <img
          className="pet-frame"
          draggable={false}
          src={simulateMissingFrame ? "/characters/__missing__/missing_0001.png" : frame}
          alt={characterName}
          onError={onFrameError}
          style={{ transform: settings.facing === "left" && animation.flipXAllowed !== false ? "scaleX(-1)" : undefined }}
        />
        <div
          className={`pet-hit-area${showDebugBounds ? " debug-visible" : ""}`}
          style={{ left: `${activeHitbox.x * 100}%`, top: `${activeHitbox.y * 100}%`, width: `${activeHitbox.width * 100}%`, height: `${activeHitbox.height * 100}%` }}
          onContextMenu={(event) => { event.preventDefault(); onContextMenu({ x: event.clientX, y: event.clientY }); }}
          onPointerDown={(event) => {
            if (event.button !== 0) return;
            gesture.current = { x: event.clientX, y: event.clientY, dragging: false };
            event.currentTarget.setPointerCapture(event.pointerId);
          }}
          onPointerMove={(event) => {
            const current = gesture.current;
            if (!current || current.dragging) return;
            if (Math.hypot(event.clientX - current.x, event.clientY - current.y) >= DRAG_THRESHOLD) {
              current.dragging = true;
              onState(interactions?.drag ?? "drag", "pointer-drag", true);
              void startDragging();
            }
          }}
          onPointerUp={(event) => {
            const current = gesture.current;
            if (!current) return;
            gesture.current = null;
            if (current.dragging) onState(interactions?.land ?? "land", "pointer-release", true);
            else if (event.detail >= 2) trigger(interactions?.doubleClick ?? "happy", "double-click");
            else trigger(interactions?.click ?? "click", "click");
          }}
          onPointerEnter={() => trigger(interactions?.hover ?? "blink", "hover")}
        />
        {showDebugBounds && <><span className="anchor-x" style={{ left: `${anchor.x * 100}%` }} /><span className="anchor-y" style={{ top: `${anchor.y * 100}%` }} /></>}
      </div>
    </main>
  );
}
