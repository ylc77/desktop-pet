import { useEffect, useMemo, useState } from "react";
import { AnimationStateMachine, type StateSnapshot } from "../core/animation/AnimationStateMachine";
import { getFrameDelay, nextFrameIndex } from "../core/animation/framePreloader";
import type { LoadedCharacter } from "../core/character/types";

export function useAnimationPlayer(character: LoadedCharacter, paused: boolean) {
  const machine = useMemo(() => new AnimationStateMachine(character), [character]);
  const [snapshot, setSnapshot] = useState<StateSnapshot>(machine.snapshot);
  const [frameIndex, setFrameIndex] = useState(0);

  useEffect(() => machine.subscribe((next) => { setFrameIndex(0); setSnapshot(next); }), [machine]);

  useEffect(() => {
    if (paused) return;
    const animation = machine.definition;
    const timer = window.setInterval(() => setFrameIndex((current) => {
      const next = nextFrameIndex(current, animation.frames.length, animation.loop);
      if (next.completed) queueMicrotask(() => machine.complete());
      return next.index;
    }), getFrameDelay(animation.fps));
    return () => window.clearInterval(timer);
  }, [machine, snapshot, paused]);

  useEffect(() => {
    if (paused || snapshot.state !== "idle") return;
    const min = machine.definition.minDelayMs ?? 4_000;
    const max = machine.definition.maxDelayMs ?? 9_000;
    const timer = window.setTimeout(() => machine.transition(machine.chooseAmbient(), "ambient"), min + Math.random() * Math.max(0, max - min));
    return () => window.clearTimeout(timer);
  }, [machine, snapshot, paused]);

  const animation = machine.definition;
  return { machine, snapshot, animation, frameIndex, frame: animation.frames[frameIndex] ?? character.animations.idle.frames[0] };
}

