import type { AnimationState, LoadedAnimation, LoadedCharacter } from "../character/types";

export interface StateSnapshot {
  state: AnimationState;
  reason: string;
  changedAt: number;
}

export class AnimationStateMachine {
  private current: StateSnapshot = { state: "idle", reason: "startup", changedAt: Date.now() };
  private listeners = new Set<(snapshot: StateSnapshot) => void>();

  constructor(private character: LoadedCharacter) {}

  get snapshot(): StateSnapshot { return { ...this.current }; }
  get definition(): LoadedAnimation { return this.character.animations[this.current.state] ?? this.character.animations.idle; }

  setCharacter(character: LoadedCharacter): void {
    this.character = character;
    this.transition("idle", "character-changed", true);
  }

  transition(requested: AnimationState, reason: string, force = false): boolean {
    const next = this.character.animations[requested] ? requested : "idle";
    const currentDefinition = this.definition;
    const nextDefinition = this.character.animations[next] ?? this.character.animations.idle;
    const canInterrupt = currentDefinition.interruptible !== false;
    const priorityAllows = (nextDefinition.priority ?? 0) >= (currentDefinition.priority ?? 0);
    if (!force && (!canInterrupt || !priorityAllows)) return false;
    this.current = { state: next, reason: next === requested ? reason : `${reason}:fallback-idle`, changedAt: Date.now() };
    this.listeners.forEach((listener) => listener(this.snapshot));
    return true;
  }

  complete(): void {
    const target = this.definition.returnTo ?? "idle";
    if (!this.definition.loop) this.transition(target, `${this.current.state}-complete`, true);
  }

  chooseAmbient(random = Math.random): AnimationState {
    const candidates = (Object.entries(this.character.animations) as [AnimationState, LoadedAnimation | undefined][])
      .filter(([state, animation]) => animation && state !== "idle" && state !== "drag" && state !== "land" && (animation.weight ?? 0) > 0);
    const total = candidates.reduce((sum, [, animation]) => sum + (animation?.weight ?? 0), 0);
    if (total <= 0) return "idle";
    let cursor = random() * total;
    for (const [state, animation] of candidates) {
      cursor -= animation?.weight ?? 0;
      if (cursor <= 0) return state;
    }
    return "idle";
  }

  subscribe(listener: (snapshot: StateSnapshot) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
}
