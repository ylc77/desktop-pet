import type { AnimationState, LoadedAnimation, LoadedCharacter } from "../character/types";

export type RandomSource = () => number;

export interface AmbientPlan {
  state: AnimationState;
  delayMs: number;
  durationMs: number | null;
}

export function createSeededRandom(seed: number): RandomSource {
  let value = seed >>> 0;
  return () => {
    value = (value + 0x6d2b79f5) >>> 0;
    let mixed = value;
    mixed = Math.imul(mixed ^ (mixed >>> 15), mixed | 1);
    mixed ^= mixed + Math.imul(mixed ^ (mixed >>> 7), mixed | 61);
    return ((mixed ^ (mixed >>> 14)) >>> 0) / 4_294_967_296;
  };
}

function randomRange(random: RandomSource, minimum: number, maximum: number): number {
  const min = Math.max(0, Math.min(minimum, maximum));
  const max = Math.max(min, maximum);
  return min + random() * (max - min);
}

export class BehaviorScheduler {
  private recent: AnimationState[] = [];
  private lastTriggered = new Map<AnimationState, number>();

  constructor(
    private character: LoadedCharacter,
    private random: RandomSource = Math.random,
    private historyLimit = 2,
  ) {}

  setCharacter(character: LoadedCharacter): void {
    this.character = character;
    this.reset();
  }

  reset(): void {
    this.recent = [];
    this.lastTriggered.clear();
  }

  get history(): readonly AnimationState[] { return [...this.recent]; }

  plan(now: number): AmbientPlan | null {
    const all = (Object.entries(this.character.animations) as [AnimationState, LoadedAnimation | undefined][])
      .filter(([state, animation]) => animation && !["idle", "drag", "land"].includes(state) && (animation.weight ?? 0) > 0);
    if (all.length === 0) return null;

    const mostRecent = this.recent.at(-1);
    const withoutImmediateRepeat = all.length > 1 ? all.filter(([state]) => state !== mostRecent) : all;
    const eligible = withoutImmediateRepeat.filter(([state, animation]) => {
      const last = this.lastTriggered.get(state);
      return last === undefined || now - last >= (animation?.minDelayMs ?? 0);
    });
    const candidates = eligible.length > 0 ? eligible : withoutImmediateRepeat;
    const total = candidates.reduce((sum, [, animation]) => sum + (animation?.weight ?? 0), 0);
    if (total <= 0) return null;
    let cursor = this.random() * total;
    let selected = candidates[candidates.length - 1];
    for (const candidate of candidates) {
      cursor -= candidate[1]?.weight ?? 0;
      if (cursor <= 0) { selected = candidate; break; }
    }
    const [state, animation] = selected;
    const idle = this.character.animations.idle;
    const minDelay = animation?.minDelayMs ?? idle.minDelayMs ?? 4_000;
    const maxDelay = animation?.maxDelayMs ?? idle.maxDelayMs ?? 9_000;
    const durationMs = animation?.minDurationMs === undefined && animation?.maxDurationMs === undefined
      ? null
      : randomRange(this.random, animation.minDurationMs ?? animation.maxDurationMs ?? 0, animation.maxDurationMs ?? animation.minDurationMs ?? 0);
    return { state, delayMs: randomRange(this.random, minDelay, maxDelay), durationMs };
  }

  record(state: AnimationState, now: number): void {
    this.lastTriggered.set(state, now);
    this.recent.push(state);
    if (this.recent.length > this.historyLimit) this.recent.splice(0, this.recent.length - this.historyLimit);
  }
}
