import { z } from "zod";
import type { CharacterManifest, ValidationResult } from "./types";

const animationStateSchema = z.string().regex(/^[a-z][a-z0-9_-]*$/, "动作名只能使用小写英文、数字、下划线和连字符");

const safeRelativePath = z.string().min(1).refine(
  (value) => !value.startsWith("/") && !value.includes("..") && !/^[a-zA-Z]:/.test(value),
  "路径必须位于角色目录内",
);

const animationSchema = z.object({
  path: safeRelativePath,
  fps: z.number().min(1).max(60),
  loop: z.boolean(),
  returnTo: animationStateSchema.optional(),
  interruptible: z.boolean().optional(),
  priority: z.number().int().min(0).max(1000).optional(),
  weight: z.number().min(0).max(1000).optional(),
  minDelayMs: z.number().int().min(0).optional(),
  maxDelayMs: z.number().int().min(0).optional(),
  minDurationMs: z.number().int().min(100).max(120_000).optional(),
  maxDurationMs: z.number().int().min(100).max(120_000).optional(),
  anticipation: animationStateSchema.optional(),
  recovery: animationStateSchema.optional(),
  offsetX: z.number().optional(),
  offsetY: z.number().optional(),
  scale: z.number().positive().max(10).optional(),
  flipXAllowed: z.boolean().optional(),
  movement: z.object({
    speed: z.number().positive().max(500),
    acceleration: z.number().positive().max(2_000).optional(),
    deceleration: z.number().positive().max(2_000).optional(),
    edgePadding: z.number().min(0).max(512).optional(),
    direction: z.enum(["left", "right"]).optional(),
    reverseTo: animationStateSchema.optional(),
  }).optional(),
}).superRefine((animation, context) => {
  if (animation.minDelayMs !== undefined && animation.maxDelayMs !== undefined && animation.minDelayMs > animation.maxDelayMs) {
    context.addIssue({ code: "custom", path: ["minDelayMs"], message: "minDelayMs 不能大于 maxDelayMs" });
  }
  if (animation.minDurationMs !== undefined && animation.maxDurationMs !== undefined && animation.minDurationMs > animation.maxDurationMs) {
    context.addIssue({ code: "custom", path: ["minDurationMs"], message: "minDurationMs 不能大于 maxDurationMs" });
  }
});

export const characterManifestSchema = z.object({
  schemaVersion: z.literal(1),
  id: z.string().regex(/^[a-z0-9_][a-z0-9_-]*$/),
  name: z.string().min(1),
  version: z.string().min(1),
  author: z.string().min(1),
  license: z.string().min(1),
  defaultScale: z.number().positive().max(4),
  frameSize: z.object({ width: z.number().int().min(16).max(4096), height: z.number().int().min(16).max(4096) }),
  anchor: z.object({ x: z.number().min(0).max(1), y: z.number().min(0).max(1) }),
  hitbox: z.object({
    x: z.number().min(0).max(1),
    y: z.number().min(0).max(1),
    width: z.number().positive().max(1),
    height: z.number().positive().max(1),
  }).refine((box) => box.x + box.width <= 1 && box.y + box.height <= 1, "点击区域不能超出画布").optional(),
  visual: z.object({
    dropShadow: z.boolean().optional(),
    groundShadow: z.object({
      enabled: z.boolean(),
      width: z.number().positive().max(2).optional(),
      height: z.number().positive().max(1).optional(),
      opacity: z.number().min(0).max(0.5).optional(),
      blur: z.number().min(0).max(32).optional(),
    }).optional(),
  }).optional(),
  preview: safeRelativePath.optional(),
  icon: safeRelativePath.optional(),
  animations: z.record(animationStateSchema, animationSchema).refine((value) => Boolean(value.idle), "必须提供 idle 动画"),
  interactions: z.object({
    click: animationStateSchema.optional(),
    doubleClick: animationStateSchema.optional(),
    hover: animationStateSchema.optional(),
    drag: animationStateSchema.optional(),
    land: animationStateSchema.optional(),
    cooldownMs: z.number().int().min(0).optional(),
  }).optional(),
  skins: z.record(z.string(), z.object({ name: z.string(), filter: z.string().optional() })).optional(),
});

export function validateManifest(input: unknown): ValidationResult & { manifest?: CharacterManifest } {
  const result = characterManifestSchema.safeParse(input);
  if (!result.success) {
    return {
      valid: false,
      errors: result.error.issues.map((issue) => `${issue.path.join(".") || "manifest"}: ${issue.message}`),
      warnings: [],
    };
  }
  const warnings: string[] = [];
  const available = new Set(Object.keys(result.data.animations));
  for (const [state, animation] of Object.entries(result.data.animations)) {
    if (animation.returnTo && !available.has(animation.returnTo)) warnings.push(`${state}: returnTo 指向缺失动作 ${animation.returnTo}，运行时将回退到 idle`);
    if (animation.anticipation && !available.has(animation.anticipation)) warnings.push(`${state}: anticipation 指向缺失动作 ${animation.anticipation}，运行时将跳过前摇`);
    if (animation.recovery && !available.has(animation.recovery)) warnings.push(`${state}: recovery 指向缺失动作 ${animation.recovery}，运行时将跳过收尾`);
    if (animation.movement?.reverseTo && !available.has(animation.movement.reverseTo)) warnings.push(`${state}: movement.reverseTo 指向缺失动作 ${animation.movement.reverseTo}，运行时将安全回退到 idle`);
    for (const phase of [animation.anticipation, animation.recovery]) {
      if (phase && available.has(phase) && result.data.animations[phase]?.loop) warnings.push(`${state}: 阶段动作 ${phase} 为循环动画，阶段序列不会自动完成`);
    }
  }
  for (const [event, target] of Object.entries(result.data.interactions ?? {})) {
    if (event !== "cooldownMs" && typeof target === "string" && !available.has(target)) warnings.push(`interactions.${event} 指向缺失动作 ${target}，运行时将回退到 idle`);
  }
  return { valid: true, errors: [], warnings, manifest: result.data as CharacterManifest };
}
