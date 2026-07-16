export interface AnimationClockState {
  frameIndex: number;
  accumulatorMs: number;
  completed: boolean;
  droppedFrames: number;
}

export interface AnimationClockOptions {
  fps: number;
  frameCount: number;
  loop: boolean;
  playbackRate?: number;
  maxCatchUpMs?: number;
  maxFrameAdvance?: number;
}

export interface AnimationClockAdvance extends AnimationClockState {
  advancedFrames: number;
  wrapped: boolean;
  capped: boolean;
}

export function createAnimationClock(frameIndex = 0): AnimationClockState {
  return { frameIndex, accumulatorMs: 0, completed: false, droppedFrames: 0 };
}

export function advanceAnimationClock(
  state: AnimationClockState,
  elapsedMs: number,
  options: AnimationClockOptions,
): AnimationClockAdvance {
  const frameCount = Math.max(1, Math.floor(options.frameCount));
  const fps = Math.max(1, Math.min(60, options.fps));
  const playbackRate = Math.max(0, options.playbackRate ?? 1);
  const maxCatchUpMs = Math.max(0, options.maxCatchUpMs ?? 250);
  const maxFrameAdvance = Math.max(1, Math.floor(options.maxFrameAdvance ?? 4));
  const safeElapsed = Number.isFinite(elapsedMs) ? Math.max(0, Math.min(elapsedMs, maxCatchUpMs)) : 0;
  const capped = Number.isFinite(elapsedMs) && elapsedMs > maxCatchUpMs;
  const frameDuration = 1000 / fps;
  const accumulated = state.accumulatorMs + safeElapsed * playbackRate;
  const availableSteps = Math.floor(accumulated / frameDuration);
  const appliedSteps = Math.min(availableSteps, maxFrameAdvance);
  const droppedThisTick = Math.max(0, availableSteps - appliedSteps);
  const accumulatorMs = accumulated - availableSteps * frameDuration;

  if (state.completed || availableSteps === 0) {
    return {
      ...state,
      accumulatorMs,
      advancedFrames: 0,
      wrapped: false,
      capped,
    };
  }

  if (options.loop) {
    const rawIndex = state.frameIndex + appliedSteps;
    return {
      frameIndex: rawIndex % frameCount,
      accumulatorMs,
      completed: false,
      droppedFrames: state.droppedFrames + droppedThisTick,
      advancedFrames: appliedSteps,
      wrapped: rawIndex >= frameCount,
      capped,
    };
  }

  const finalIndex = frameCount - 1;
  const stepsUntilFinal = Math.max(0, finalIndex - state.frameIndex);
  const completed = appliedSteps > stepsUntilFinal;
  return {
    frameIndex: Math.min(finalIndex, state.frameIndex + appliedSteps),
    accumulatorMs,
    completed,
    droppedFrames: state.droppedFrames + droppedThisTick,
    advancedFrames: Math.min(appliedSteps, stepsUntilFinal),
    wrapped: false,
    capped,
  };
}
