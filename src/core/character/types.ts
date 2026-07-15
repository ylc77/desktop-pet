export const CORE_ANIMATION_STATES = ["idle", "blink", "walk", "sleep", "click", "drag", "land", "happy"] as const;
export type AnimationState = string;

export interface AnimationDefinition {
  path: string;
  fps: number;
  loop: boolean;
  returnTo?: AnimationState;
  interruptible?: boolean;
  priority?: number;
  weight?: number;
  minDelayMs?: number;
  maxDelayMs?: number;
  offsetX?: number;
  offsetY?: number;
  scale?: number;
  flipXAllowed?: boolean;
}

export interface CharacterManifest {
  schemaVersion: 1;
  id: string;
  name: string;
  version: string;
  author: string;
  license: string;
  defaultScale: number;
  frameSize: { width: number; height: number };
  anchor: { x: number; y: number };
  hitbox?: { x: number; y: number; width: number; height: number };
  preview?: string;
  icon?: string;
  animations: Partial<Record<AnimationState, AnimationDefinition>> & { idle: AnimationDefinition };
  interactions?: {
    click?: AnimationState;
    doubleClick?: AnimationState;
    hover?: AnimationState;
    drag?: AnimationState;
    land?: AnimationState;
    cooldownMs?: number;
  };
  skins?: Record<string, { name: string; filter?: string }>;
}

export interface LoadedAnimation extends AnimationDefinition {
  state: AnimationState;
  frames: string[];
}

export interface LoadedCharacter {
  manifest: CharacterManifest;
  animations: Partial<Record<AnimationState, LoadedAnimation>> & { idle: LoadedAnimation };
  baseUrl: string;
  warnings: string[];
}

export interface ValidationResult {
  valid: boolean;
  errors: string[];
  warnings: string[];
}
