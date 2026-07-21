import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { flushSync } from "react-dom";
import type { AppSettings } from "../../core/settings/settingsSchema";
import type { AnimationState, CharacterManifest, LoadedAnimation } from "../../core/character/types";
import {
  beginManualWindowDrag,
  setPetInteractionRegion,
  updateManualWindowDrag,
  type ManualWindowDragSession,
} from "../../core/window/windowController";
import { normalizePetInteractionRegion, samePetInteractionRegion, type NormalizedPetInteractionRegion } from "../../core/window/petInteractionRegion";
import { log } from "../../core/diagnostics/logger";
import { anchorLayout, mirroredHitbox } from "../../core/animation/renderGeometry";
import { clampPetScaleToFit, getPetFitScale, type PetViewportSize } from "../../core/animation/petScale";
import { ClickArbiter, DOUBLE_CLICK_WINDOW_MS, exceedsDragThreshold } from "../../core/animation/interactionArbiter";

interface Props {
  frame: string;
  animation: LoadedAnimation;
  settings: AppSettings;
  frameSize: { width: number; height: number };
  anchor: { x: number; y: number };
  viewport: PetViewportSize;
  hitbox?: CharacterManifest["hitbox"];
  visual?: CharacterManifest["visual"];
  characterName: string;
  interactions?: CharacterManifest["interactions"];
  dragMovementStates?: Partial<Record<"left" | "right", AnimationState>>;
  dragMovementPreviews?: Partial<Record<"left" | "right", string>>;
  interactionOverlayActive?: boolean;
  showDebugBounds: boolean;
  simulateMissingFrame: boolean;
  onState: (state: AnimationState, reason: string, force?: boolean) => boolean;
  onInputDiagnostic: (event: string, latencyMs: number) => void;
  onContextMenu: (position: { x: number; y: number }) => void;
  onFrameError: () => void;
}

interface FrameLayers { sources: [string, string]; active: 0 | 1; pending: 0 | 1 | null }

export function resolveDragMovementState(
  horizontalDelta: number,
  facing: "left" | "right",
  directionalStates: Props["dragMovementStates"],
  fallback: AnimationState,
): AnimationState {
  const direction = horizontalDelta < 0 ? "left" : horizontalDelta > 0 ? "right" : facing;
  return directionalStates?.[direction] ?? fallback;
}

export function BufferedFrame({ source, dropShadow, onError }: { source: string; dropShadow: boolean; onError: () => void }) {
  const [layers, setLayers] = useState<FrameLayers>({ sources: [source, source], active: 0, pending: null });
  const layersRef = useRef(layers);
  const loadedRef = useRef<[boolean, boolean]>([false, false]);
  layersRef.current = layers;
  useEffect(() => {
    setLayers((current) => {
      if (current.sources[current.active] === source) {
        return current.pending === null ? current : { ...current, pending: null };
      }
      const pending = (current.active === 0 ? 1 : 0) as 0 | 1;
      if (current.sources[pending] === source && loadedRef.current[pending]) {
        return { ...current, active: pending, pending: null };
      }
      const sources: [string, string] = [...current.sources] as [string, string];
      sources[pending] = source;
      loadedRef.current[pending] = false;
      return { ...current, sources, pending };
    });
  }, [source]);
  return <div className={`pet-frame-buffer${dropShadow ? " with-drop-shadow" : ""}`}>
    {layers.sources.map((frameSource, index) => <img
      key={`${index}:${frameSource}`}
      className={`pet-frame${layers.active === index ? " active" : ""}`}
      draggable={false}
      src={frameSource}
      alt=""
      aria-hidden="true"
      onLoad={() => {
        const current = layersRef.current;
        if (current.sources[index] !== frameSource) return;
        loadedRef.current[index as 0 | 1] = true;
        if (current.pending !== index) return;
        const next = { ...current, active: index as 0 | 1, pending: null };
        layersRef.current = next;
        setLayers(next);
      }}
      onError={() => {
        const current = layersRef.current;
        if (current.pending !== index || current.sources[index] !== frameSource) return;
        loadedRef.current[index as 0 | 1] = false;
        const next = { ...current, pending: null };
        layersRef.current = next;
        setLayers(next);
        onError();
      }}
    />)}
  </div>;
}

export function PetCanvas({ frame, animation, settings, frameSize, anchor, viewport, hitbox, visual, characterName, interactions, dragMovementStates, dragMovementPreviews, interactionOverlayActive = false, showDebugBounds, simulateMissingFrame, onState, onInputDiagnostic, onContextMenu, onFrameError }: Props) {
  const hitAreaRef = useRef<HTMLDivElement>(null);
  const publishedInteractionRegion = useRef<NormalizedPetInteractionRegion | null>(null);
  const gesture = useRef<{
    x: number;
    y: number;
    screenX: number;
    screenY: number;
    pointerId: number;
    dragging: boolean;
    dragState: AnimationState | null;
  } | null>(null);
  const manualDragSession = useRef<Promise<ManualWindowDragSession | null> | null>(null);
  const queuedManualMove = useRef<{ pointerId: number; x: number; y: number; startedAt: number } | null>(null);
  const manualMoveFrame = useRef<number | null>(null);
  const lastTapInteraction = useRef(Number.NEGATIVE_INFINITY);
  const lastHoverInteraction = useRef(Number.NEGATIVE_INFINITY);
  const clickArbiter = useRef(new ClickArbiter());
  const pendingClickTimer = useRef<number | null>(null);
  const hoverTimer = useRef<number | null>(null);
  const hoverArmed = useRef(false);
  const [dragPreviewDirection, setDragPreviewDirection] = useState<"left" | "right" | null>(null);
  const dragPreviewDirectionRef = useRef<"left" | "right" | null>(null);
  const mirrored = animation.movement?.direction === undefined && settings.facing === "left" && animation.flipXAllowed !== false;
  const activeAnchor = { x: mirrored ? 1 - anchor.x : anchor.x, y: anchor.y };
  const fitScale = getPetFitScale(frameSize, activeAnchor, viewport);
  const effectiveScale = clampPetScaleToFit(settings.scale * (animation.scale ?? 1), fitScale);
  const activeHitbox = mirroredHitbox(hitbox ?? { x: 0, y: 0, width: 1, height: 1 }, mirrored);
  const cooldown = interactions?.cooldownMs ?? 350;
  const desiredFrame = simulateMissingFrame ? "/characters/__missing__/missing_0001.png" : frame;
  const groundShadow = visual?.groundShadow;

  useLayoutEffect(() => {
    const element = hitAreaRef.current;
    if (!element) return;

    const frameId = window.requestAnimationFrame(() => {
      const region = interactionOverlayActive
        ? null
        : normalizePetInteractionRegion(element.getBoundingClientRect(), {
          width: window.innerWidth,
          height: window.innerHeight,
        });
      if (samePetInteractionRegion(region, publishedInteractionRegion.current)) return;
      publishedInteractionRegion.current = region;
      void setPetInteractionRegion(region).catch((error) => {
        log("warn", "无法同步桌宠鼠标穿透区域，已保留普通窗口交互", error);
      });
    });

    return () => window.cancelAnimationFrame(frameId);
  }, [
    activeAnchor.x,
    activeAnchor.y,
    activeHitbox.height,
    activeHitbox.width,
    activeHitbox.x,
    activeHitbox.y,
    animation.offsetX,
    animation.offsetY,
    effectiveScale,
    frameSize.height,
    frameSize.width,
    interactionOverlayActive,
    viewport.height,
    viewport.width,
  ]);

  useEffect(() => () => {
    publishedInteractionRegion.current = null;
    void setPetInteractionRegion(null).catch(() => undefined);
  }, []);

  useEffect(() => () => {
    if (pendingClickTimer.current !== null) window.clearTimeout(pendingClickTimer.current);
    if (hoverTimer.current !== null) window.clearTimeout(hoverTimer.current);
    if (manualMoveFrame.current !== null) window.cancelAnimationFrame(manualMoveFrame.current);
  }, []);

  const reportInput = (name: string, startedAt: number) => onInputDiagnostic(name, Math.max(0, performance.now() - startedAt));
  const triggerTap = (state: AnimationState, reason: string, startedAt: number) => {
    if (!settings.interactionsEnabled || performance.now() - lastTapInteraction.current < cooldown) return false;
    const accepted = onState(state, reason);
    if (accepted) lastTapInteraction.current = performance.now();
    reportInput(reason, startedAt);
    return accepted;
  };

  const clearPendingClickTimer = () => {
    if (pendingClickTimer.current !== null) window.clearTimeout(pendingClickTimer.current);
    pendingClickTimer.current = null;
  };

  const showDragPreview = (state: AnimationState) => {
    const direction = state === dragMovementStates?.left
      ? "left"
      : state === dragMovementStates?.right
        ? "right"
        : null;
    if (!direction || !dragMovementPreviews?.[direction] || dragPreviewDirectionRef.current === direction) return;
    dragPreviewDirectionRef.current = direction;
    flushSync(() => setDragPreviewDirection(direction));
  };

  const clearDragPreview = () => {
    if (dragPreviewDirectionRef.current === null) return;
    dragPreviewDirectionRef.current = null;
    setDragPreviewDirection(null);
  };

  const finishDrag = (reason: string, startedAt: number) => {
    const current = gesture.current;
    if (!current) return;
    gesture.current = null;
    manualDragSession.current = null;
    queuedManualMove.current = null;
    if (manualMoveFrame.current !== null) window.cancelAnimationFrame(manualMoveFrame.current);
    manualMoveFrame.current = null;
    clearDragPreview();
    if (current.dragging) {
      onState(interactions?.land ?? "land", reason, true);
      reportInput(reason, startedAt);
    }
  };

  const queueManualWindowMove = (pointerId: number, x: number, y: number, startedAt: number) => {
    queuedManualMove.current = { pointerId, x, y, startedAt };
    if (manualMoveFrame.current !== null) return;
    manualMoveFrame.current = window.requestAnimationFrame(() => {
      manualMoveFrame.current = null;
      const next = queuedManualMove.current;
      const sessionPromise = manualDragSession.current;
      queuedManualMove.current = null;
      if (!next || !sessionPromise) return;
      void sessionPromise.then(async (session) => {
        const current = gesture.current;
        if (!current || current.pointerId !== next.pointerId || !current.dragging) return;
        await updateManualWindowDrag(session, { x: next.x, y: next.y });
      }).catch((error) => {
        log("warn", "桌宠跟随鼠标移动失败，已安全恢复", error);
        finishDrag("manual-drag-failed", next.startedAt);
      });
    });
  };

  return (
    <main className="pet-stage" role="img" aria-label={characterName}>
      <div className="pet-anchor-layout" style={{ width: frameSize.width, height: frameSize.height, ...anchorLayout(activeAnchor) }}>
        <div
          className={`pet-transform${showDebugBounds ? " debug-canvas" : ""}`}
          style={{
            width: frameSize.width,
            height: frameSize.height,
            transform: `scale(${effectiveScale}) translate(${animation.offsetX ?? 0}px, ${animation.offsetY ?? 0}px)`,
            transformOrigin: `${activeAnchor.x * 100}% ${activeAnchor.y * 100}%`,
            opacity: settings.opacity,
          }}
        >
          {groundShadow?.enabled && <div className="pet-ground-shadow" style={{
            left: `${activeAnchor.x * 100}%`, top: `${activeAnchor.y * 100}%`,
            width: `${(groundShadow.width ?? 0.42) * 100}%`, height: `${(groundShadow.height ?? 0.08) * 100}%`,
            opacity: groundShadow.opacity ?? 0.18, filter: `blur(${groundShadow.blur ?? 5}px)`,
          }} />}
          <div className={`pet-content${dragPreviewDirection ? " drag-preview-active" : ""}`} style={{ transform: mirrored ? "scaleX(-1)" : undefined }}>
            <BufferedFrame source={desiredFrame} dropShadow={visual?.dropShadow !== false} onError={onFrameError} />
            {dragMovementPreviews?.left && <img
              className={`pet-drag-preview${dragPreviewDirection === "left" ? " active" : ""}`}
              draggable={false}
              src={dragMovementPreviews.left}
              alt=""
              aria-hidden="true"
            />}
            {dragMovementPreviews?.right && <img
              className={`pet-drag-preview${dragPreviewDirection === "right" ? " active" : ""}`}
              draggable={false}
              src={dragMovementPreviews.right}
              alt=""
              aria-hidden="true"
            />}
          </div>
          <div
            ref={hitAreaRef}
            className={`pet-hit-area${showDebugBounds ? " debug-visible" : ""}`}
            style={{ left: `${activeHitbox.x * 100}%`, top: `${activeHitbox.y * 100}%`, width: `${activeHitbox.width * 100}%`, height: `${activeHitbox.height * 100}%` }}
            onContextMenu={(event) => { event.preventDefault(); onContextMenu({ x: event.clientX, y: event.clientY }); }}
            onPointerDown={(event) => {
              if (event.button !== 0) return;
              gesture.current = {
                x: event.clientX,
                y: event.clientY,
                screenX: event.screenX,
                screenY: event.screenY,
                pointerId: event.pointerId,
                dragging: false,
                dragState: null,
              };
              manualDragSession.current = beginManualWindowDrag({ x: event.screenX, y: event.screenY });
              event.currentTarget.setPointerCapture(event.pointerId);
            }}
            onPointerMove={(event) => {
              const current = gesture.current;
              if (!current || current.pointerId !== event.pointerId) return;
              if (!current.dragging && exceedsDragThreshold(current, { x: event.clientX, y: event.clientY })) {
                current.dragging = true;
                clearPendingClickTimer();
                clickArbiter.current.cancel();
              }
              if (!current.dragging) return;
              const nextState = resolveDragMovementState(
                event.screenX - current.screenX,
                settings.facing,
                dragMovementStates,
                interactions?.drag ?? "drag",
              );
              if (current.dragState !== nextState) {
                current.dragState = nextState;
                showDragPreview(nextState);
                onState(nextState, "pointer-drag", true);
              }
              queueManualWindowMove(event.pointerId, event.screenX, event.screenY, event.timeStamp);
            }}
            onPointerUp={(event) => {
              const current = gesture.current;
              if (!current || current.pointerId !== event.pointerId) return;
              if (current.dragging) { finishDrag("pointer-release", event.timeStamp); return; }
              gesture.current = null;
              manualDragSession.current = null;
              const result = clickArbiter.current.release(event.timeStamp);
              if (result === "double-click") {
                clearPendingClickTimer();
                triggerTap(interactions?.doubleClick ?? "happy", "double-click", event.timeStamp);
              } else {
                clearPendingClickTimer();
                const startedAt = event.timeStamp;
                pendingClickTimer.current = window.setTimeout(() => {
                  pendingClickTimer.current = null;
                  if (clickArbiter.current.consumePending()) triggerTap(interactions?.click ?? "click", "click", startedAt);
                }, DOUBLE_CLICK_WINDOW_MS);
              }
            }}
            onPointerCancel={(event) => finishDrag("pointer-cancel", event.timeStamp)}
            onLostPointerCapture={(event) => finishDrag("pointer-capture-lost", event.timeStamp)}
            onPointerEnter={(event) => {
              if (!settings.interactionsEnabled || hoverArmed.current) return;
              hoverArmed.current = true;
              const startedAt = event.timeStamp;
              hoverTimer.current = window.setTimeout(() => {
                hoverTimer.current = null;
                if (!hoverArmed.current || performance.now() - lastHoverInteraction.current < cooldown) return;
                if (onState(interactions?.hover ?? "blink", "hover")) lastHoverInteraction.current = performance.now();
                reportInput("hover", startedAt);
              }, 80);
            }}
            onPointerLeave={() => {
              hoverArmed.current = false;
              if (hoverTimer.current !== null) window.clearTimeout(hoverTimer.current);
              hoverTimer.current = null;
            }}
          />
          {showDebugBounds && <><span className="anchor-x" style={{ left: `${activeAnchor.x * 100}%` }} /><span className="anchor-y" style={{ top: `${activeAnchor.y * 100}%` }} /></>}
        </div>
      </div>
    </main>
  );
}
