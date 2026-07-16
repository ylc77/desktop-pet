import { useEffect, useRef, useState } from "react";
import { currentMonitor, getCurrentWindow, PhysicalPosition } from "@tauri-apps/api/window";
import type { LoadedAnimation } from "../core/character/types";
import { stepMotion, type MotionState } from "../core/animation/motionModel";
import { isTauriRuntime } from "../core/window/windowController";
import { log } from "../core/diagnostics/logger";

export interface MotionDiagnostics {
  active: boolean;
  speed: number;
  monitor: string | null;
  dpiScale: number;
}

export function usePetMotion(
  animation: LoadedAnimation,
  facing: "left" | "right",
  suspended: boolean,
  onFacingChange: (facing: "left" | "right", reverseTo?: string) => void,
): MotionDiagnostics {
  const [diagnostics, setDiagnostics] = useState<MotionDiagnostics>({ active: false, speed: 0, monitor: null, dpiScale: window.devicePixelRatio || 1 });
  const facingCallback = useRef(onFacingChange);
  facingCallback.current = onFacingChange;

  useEffect(() => {
    if (!animation.movement || suspended || !isTauriRuntime()) {
      setDiagnostics((current) => ({ ...current, active: false, speed: 0 }));
      return;
    }
    let disposed = false;
    let requestId = 0;
    void (async () => {
      try {
        const windowHandle = getCurrentWindow();
        const [monitor, position, size] = await Promise.all([currentMonitor(), windowHandle.outerPosition(), windowHandle.outerSize()]);
        if (disposed || !monitor) return;
        const scale = monitor.scaleFactor;
        const work = monitor.workArea;
        const movement = animation.movement!;
        const minimum = work.position.x;
        const maximum = Math.max(minimum, work.position.x + work.size.width - size.width);
        const initialFacing = movement.direction ?? facing;
        if (movement.direction && movement.direction !== facing) facingCallback.current(movement.direction);
        let state: MotionState = { position: position.x, velocity: 0, direction: initialFacing === "left" ? -1 : 1 };
        let moveFailed = false;
        let moveInFlight = false;
        let last = performance.now();
        let lastWindowUpdate = last;
        let lastDiagnostic = last;
        setDiagnostics({ active: true, speed: 0, monitor: monitor.name, dpiScale: scale });
        const tick = (now: number) => {
          if (disposed || moveFailed) return;
          const elapsed = Math.min(100, now - last);
          last = now;
          const next = stepMotion(state, elapsed, { minimum, maximum }, {
            speed: movement.speed * scale,
            acceleration: (movement.acceleration ?? movement.speed * 3) * scale,
            deceleration: (movement.deceleration ?? movement.speed * 4) * scale,
            edgePadding: (movement.edgePadding ?? 20) * scale,
          });
          state = next;
          if (next.reversed) facingCallback.current(next.direction < 0 ? "left" : "right", movement.reverseTo);
          if (now - lastWindowUpdate >= 33 && !moveInFlight) {
            lastWindowUpdate = now;
            moveInFlight = true;
            void windowHandle.setPosition(new PhysicalPosition(Math.round(next.position), position.y))
              .catch((error) => {
                if (disposed) return;
                moveFailed = true;
                cancelAnimationFrame(requestId);
                setDiagnostics((current) => ({ ...current, active: false, speed: 0 }));
                log("warn", "平滑移动窗口失败，已停止本次移动", error);
              })
              .finally(() => { moveInFlight = false; });
          }
          if (now - lastDiagnostic >= 250) {
            lastDiagnostic = now;
            setDiagnostics({ active: true, speed: Math.abs(next.velocity) / scale, monitor: monitor.name, dpiScale: scale });
          }
          requestId = requestAnimationFrame(tick);
        };
        requestId = requestAnimationFrame(tick);
      } catch (error) {
        log("warn", "无法初始化桌宠平滑移动", error);
      }
    })();
    return () => {
      disposed = true;
      cancelAnimationFrame(requestId);
      setDiagnostics((current) => ({ ...current, active: false, speed: 0 }));
    };
  }, [animation, facing, suspended]);

  return diagnostics;
}
