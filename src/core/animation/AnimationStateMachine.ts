import type { AnimationState, LoadedAnimation, LoadedCharacter } from "../character/types";

export interface StateSnapshot {
  state: AnimationState;
  previousState: AnimationState | null;
  nextCandidate: AnimationState | null;
  reason: string;
  changedAt: number;
  priority: number;
  forced: boolean;
}

export interface TransitionDiagnostic {
  requested: AnimationState;
  current: AnimationState;
  accepted: boolean;
  forced: boolean;
  reason: string;
  rejectedBy: "non-interruptible" | "priority" | "same-state" | null;
}

export class AnimationStateMachine {
  private current: StateSnapshot;
  private listeners = new Set<(snapshot: StateSnapshot) => void>();
  private pending: { state: AnimationState; reason: string }[] = [];
  private diagnostics: TransitionDiagnostic[] = [];

  constructor(private character: LoadedCharacter, private now: () => number = () => performance.now()) {
    this.current = { state: "idle", previousState: null, nextCandidate: null, reason: "startup", changedAt: this.now(), priority: character.animations.idle.priority ?? 0, forced: false };
  }

  get snapshot(): StateSnapshot { return { ...this.current }; }
  get definition(): LoadedAnimation { return this.character.animations[this.current.state] ?? this.character.animations.idle; }
  get queue(): readonly AnimationState[] { return this.pending.map((entry) => entry.state); }
  get recentTransitions(): readonly TransitionDiagnostic[] { return [...this.diagnostics]; }

  setCharacter(character: LoadedCharacter): void {
    this.character = character;
    this.pending = [];
    this.transition("idle", "character-changed", true);
  }

  transition(requested: AnimationState, reason: string, force = false): boolean {
    const next = this.character.animations[requested] ? requested : "idle";
    const currentDefinition = this.definition;
    const nextDefinition = this.character.animations[next] ?? this.character.animations.idle;
    const canInterrupt = currentDefinition.interruptible !== false;
    const priorityAllows = (nextDefinition.priority ?? 0) >= (currentDefinition.priority ?? 0);
    const rejectedBy = !force && next === this.current.state ? "same-state" : !force && !canInterrupt ? "non-interruptible" : !force && !priorityAllows ? "priority" : null;
    this.recordDiagnostic({ requested, current: this.current.state, accepted: rejectedBy === null, forced: force, reason, rejectedBy });
    if (rejectedBy) return false;

    const plan: { state: AnimationState; reason: string }[] = [];
    if (nextDefinition.anticipation && this.character.animations[nextDefinition.anticipation]) {
      plan.push({ state: nextDefinition.anticipation, reason: `${reason}:anticipation` });
    }
    plan.push({ state: next, reason: next === requested ? reason : `${reason}:fallback-idle` });
    if (nextDefinition.recovery && this.character.animations[nextDefinition.recovery]) {
      plan.push({ state: nextDefinition.recovery, reason: `${reason}:recovery` });
      const returnTo = nextDefinition.returnTo ?? "idle";
      if (returnTo !== nextDefinition.recovery) plan.push({ state: this.character.animations[returnTo] ? returnTo : "idle", reason: `${reason}:complete` });
    }
    this.pending = plan.slice(1, 4);
    this.commit(plan[0].state, plan[0].reason, force);
    return true;
  }

  complete(): void {
    if (this.pending.length > 0) {
      const next = this.pending.shift()!;
      this.commit(next.state, next.reason, true);
      return;
    }
    const target = this.definition.returnTo ?? "idle";
    if (!this.definition.loop) this.transition(target, `${this.current.state}-complete`, true);
  }

  exitCurrent(reason: string): void {
    const definition = this.definition;
    const target = definition.returnTo ?? "idle";
    this.pending = [];
    if (definition.recovery && this.character.animations[definition.recovery]) {
      this.pending.push({ state: this.character.animations[target] ? target : "idle", reason: `${reason}:complete` });
      this.commit(definition.recovery, `${reason}:recovery`, true);
      return;
    }
    this.transition(target, reason, true);
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

  private commit(state: AnimationState, reason: string, forced: boolean): void {
    const previousState = this.current.state;
    const definition = this.character.animations[state] ?? this.character.animations.idle;
    this.current = {
      state,
      previousState,
      nextCandidate: this.pending[0]?.state ?? null,
      reason,
      changedAt: this.now(),
      priority: definition.priority ?? 0,
      forced,
    };
    this.listeners.forEach((listener) => listener(this.snapshot));
  }

  private recordDiagnostic(diagnostic: TransitionDiagnostic): void {
    this.diagnostics.push(diagnostic);
    if (this.diagnostics.length > 24) this.diagnostics.shift();
  }
}
