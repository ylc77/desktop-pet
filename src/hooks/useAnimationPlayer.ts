import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AnimationStateMachine, type StateSnapshot } from "../core/animation/AnimationStateMachine";
import { advanceAnimationClock, createAnimationClock } from "../core/animation/animationClock";
import { BehaviorScheduler, createSeededRandom } from "../core/animation/BehaviorScheduler";
import { nextFrameIndex } from "../core/animation/framePreloader";
import type { LoadedCharacter } from "../core/character/types";

export interface AnimationPlayerOptions {
  paused: boolean;
  suspended?: boolean;
  playbackRate?: number;
  ambientEnabled?: boolean;
  randomSeed?: number | null;
  forceLoop?: boolean;
}

export interface AnimationDiagnostics {
  actualFrameUpdates: number;
  rafFrequency: number;
  droppedFrames: number;
  cappedTicks: number;
  suspended: boolean;
  nextAmbient: string | null;
  recentAmbient: readonly string[];
  queue: readonly string[];
}

const INITIAL_DIAGNOSTICS: AnimationDiagnostics = {
  actualFrameUpdates: 0,
  rafFrequency: 0,
  droppedFrames: 0,
  cappedTicks: 0,
  suspended: false,
  nextAmbient: null,
  recentAmbient: [],
  queue: [],
};

export function useAnimationPlayer(character: LoadedCharacter, options: AnimationPlayerOptions) {
  const machine = useMemo(() => new AnimationStateMachine(character), [character]);
  const scheduler = useMemo(() => new BehaviorScheduler(character, options.randomSeed === null || options.randomSeed === undefined ? Math.random : createSeededRandom(options.randomSeed)), [character, options.randomSeed]);
  const [snapshot, setSnapshot] = useState<StateSnapshot>(machine.snapshot);
  const [frameIndex, setFrameIndex] = useState(0);
  const [documentHidden, setDocumentHidden] = useState(() => typeof document !== "undefined" && document.hidden);
  const [diagnostics, setDiagnostics] = useState<AnimationDiagnostics>(INITIAL_DIAGNOSTICS);
  const clock = useRef(createAnimationClock());
  const lastTimestamp = useRef<number | null>(null);
  const completionQueued = useRef(false);
  const pendingLoopExit = useRef(false);
  const ambientDuration = useRef<number | null>(null);
  const ambientTarget = useRef<string | null>(null);
  const metrics = useRef({ startedAt: 0, raf: 0, updates: 0, dropped: 0, capped: 0 });
  const effectiveSuspended = Boolean(options.paused || options.suspended || documentHidden);

  useEffect(() => {
    setSnapshot(machine.snapshot);
    setFrameIndex(0);
    clock.current = createAnimationClock();
    completionQueued.current = false;
    pendingLoopExit.current = false;
    ambientDuration.current = null;
    ambientTarget.current = null;
    setDiagnostics(INITIAL_DIAGNOSTICS);
    return machine.subscribe((next) => {
      clock.current = createAnimationClock();
      lastTimestamp.current = null;
      completionQueued.current = false;
      pendingLoopExit.current = false;
      if (!next.reason.startsWith("ambient") || next.state === "idle") {
        ambientDuration.current = null;
        ambientTarget.current = null;
      }
      setFrameIndex(0);
      setSnapshot(next);
      setDiagnostics((current) => ({ ...current, queue: machine.queue }));
    });
  }, [machine]);

  useEffect(() => {
    const onVisibility = () => setDocumentHidden(document.hidden);
    document.addEventListener("visibilitychange", onVisibility);
    return () => document.removeEventListener("visibilitychange", onVisibility);
  }, []);

  useEffect(() => {
    if (effectiveSuspended) {
      lastTimestamp.current = null;
      setDiagnostics((current) => ({ ...current, suspended: true }));
      return;
    }
    setDiagnostics((current) => ({ ...current, suspended: false }));
    if (options.forceLoop && clock.current.completed) {
      clock.current = { ...clock.current, completed: false };
    }
    let requestId = 0;
    metrics.current = { startedAt: performance.now(), raf: 0, updates: 0, dropped: clock.current.droppedFrames, capped: 0 };
    const tick = (now: number) => {
      metrics.current.raf += 1;
      if (lastTimestamp.current === null) lastTimestamp.current = now;
      const elapsed = now - lastTimestamp.current;
      lastTimestamp.current = now;
      const animation = machine.definition;
      const loop = animation.loop || options.forceLoop === true;
      const next = advanceAnimationClock(clock.current, elapsed, {
        fps: animation.fps,
        frameCount: animation.frames.length,
        loop,
        playbackRate: options.playbackRate ?? 1,
        maxCatchUpMs: 250,
        maxFrameAdvance: 4,
      });
      clock.current = next;
      if (next.advancedFrames > 0) {
        metrics.current.updates += next.advancedFrames;
        setFrameIndex(next.frameIndex);
      }
      if (next.capped) metrics.current.capped += 1;
      if (next.wrapped && pendingLoopExit.current) {
        pendingLoopExit.current = false;
        machine.exitCurrent("ambient-duration-complete");
      } else if (next.completed && !completionQueued.current) {
        completionQueued.current = true;
        const completedSnapshot = machine.snapshot;
        queueMicrotask(() => {
          const currentSnapshot = machine.snapshot;
          if (currentSnapshot.state === completedSnapshot.state && currentSnapshot.changedAt === completedSnapshot.changedAt) {
            machine.complete();
          }
        });
      }
      if (now - metrics.current.startedAt >= 1_000) {
        const seconds = (now - metrics.current.startedAt) / 1_000;
        setDiagnostics((current) => ({
          ...current,
          actualFrameUpdates: Number((metrics.current.updates / seconds).toFixed(1)),
          rafFrequency: Number((metrics.current.raf / seconds).toFixed(1)),
          droppedFrames: next.droppedFrames,
          cappedTicks: current.cappedTicks + metrics.current.capped,
          queue: machine.queue,
        }));
        metrics.current = { startedAt: now, raf: 0, updates: 0, dropped: next.droppedFrames, capped: 0 };
      }
      requestId = requestAnimationFrame(tick);
    };
    requestId = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(requestId);
      lastTimestamp.current = null;
    };
  }, [effectiveSuspended, machine, options.forceLoop, options.playbackRate, snapshot.state]);

  useEffect(() => {
    if (effectiveSuspended || options.ambientEnabled === false || snapshot.state !== "idle") {
      setDiagnostics((current) => ({ ...current, nextAmbient: null }));
      return;
    }
    const plan = scheduler.plan(performance.now());
    if (!plan) return;
    setDiagnostics((current) => ({ ...current, nextAmbient: plan.state }));
    const timer = window.setTimeout(() => {
      ambientTarget.current = plan.state;
      ambientDuration.current = plan.durationMs;
      if (machine.transition(plan.state, "ambient")) {
        scheduler.record(plan.state, performance.now());
        setDiagnostics((current) => ({ ...current, nextAmbient: null, recentAmbient: scheduler.history }));
      } else {
        ambientTarget.current = null;
        ambientDuration.current = null;
      }
    }, plan.delayMs);
    return () => window.clearTimeout(timer);
  }, [effectiveSuspended, machine, options.ambientEnabled, scheduler, snapshot.state]);

  useEffect(() => {
    if (
      effectiveSuspended
      || ambientDuration.current === null
      || snapshot.state !== ambientTarget.current
      || !snapshot.reason.startsWith("ambient")
      || (!machine.definition.loop && options.forceLoop !== true)
    ) return;
    const timer = window.setTimeout(() => { pendingLoopExit.current = true; }, ambientDuration.current);
    return () => window.clearTimeout(timer);
  }, [effectiveSuspended, machine, options.forceLoop, snapshot]);

  const stepFrame = useCallback(() => {
    if (!effectiveSuspended) return;
    const animation = machine.definition;
    const next = nextFrameIndex(frameIndex, animation.frames.length, animation.loop || options.forceLoop === true);
    setFrameIndex(next.index);
    if (next.completed) machine.complete();
  }, [effectiveSuspended, frameIndex, machine, options.forceLoop]);

  const animation = machine.definition;
  return {
    machine,
    snapshot,
    animation,
    frameIndex,
    frame: animation.frames[frameIndex] ?? character.animations.idle.frames[0],
    diagnostics,
    stepFrame,
  };
}
