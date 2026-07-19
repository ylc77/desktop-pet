import type { CharacterManifest } from "../character/types";

export interface PetViewportSize {
  width: number;
  height: number;
}

export const MAX_PET_SIZE_PERCENT = 100;
export const MIN_PET_SIZE_PERCENT = 10;
export const MIN_PERSISTED_PET_SCALE = 0.01;
export const MAX_PERSISTED_PET_SCALE = 4;

const FALLBACK_FIT_SCALE = 1;

function isPositiveFinite(value: number): boolean {
  return Number.isFinite(value) && value > 0;
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(maximum, Math.max(minimum, value));
}

/**
 * Returns the largest absolute canvas multiplier that keeps the declared
 * character canvas inside the logical pet viewport. The anchor remains on the
 * bottom edge, so only the canvas area above it constrains vertical sizing.
 */
export function getPetFitScale(
  frameSize: CharacterManifest["frameSize"],
  anchor: CharacterManifest["anchor"],
  viewport: PetViewportSize,
): number {
  if (!isPositiveFinite(frameSize.width)
    || !isPositiveFinite(frameSize.height)
    || !isPositiveFinite(viewport.width)
    || !isPositiveFinite(viewport.height)
    || !Number.isFinite(anchor.x)
    || !Number.isFinite(anchor.y)) {
    return FALLBACK_FIT_SCALE;
  }

  const anchorX = clamp(anchor.x, 0, 1);
  const anchorY = clamp(anchor.y, 0, 1);
  const horizontalExtent = frameSize.width * 2 * Math.max(anchorX, 1 - anchorX);
  const verticalExtent = frameSize.height * anchorY;
  const horizontalScale = viewport.width / horizontalExtent;
  const verticalScale = verticalExtent > 0 ? viewport.height / verticalExtent : Number.POSITIVE_INFINITY;
  const fitScale = Math.min(horizontalScale, verticalScale);

  if (!isPositiveFinite(fitScale)) return FALLBACK_FIT_SCALE;
  return Math.min(fitScale, MAX_PERSISTED_PET_SCALE);
}

export function clampPetScaleToFit(scale: number, fitScale: number): number {
  const safeFitScale = isPositiveFinite(fitScale) ? fitScale : FALLBACK_FIT_SCALE;
  const safeScale = isPositiveFinite(scale) ? scale : safeFitScale;
  const maximum = Math.min(safeFitScale, MAX_PERSISTED_PET_SCALE);
  const minimum = Math.min(MIN_PERSISTED_PET_SCALE, maximum);
  return clamp(safeScale, minimum, maximum);
}

export function petScaleToPercent(scale: number, fitScale: number): number {
  const safeFitScale = isPositiveFinite(fitScale) ? fitScale : FALLBACK_FIT_SCALE;
  const percentage = (clampPetScaleToFit(scale, safeFitScale) / safeFitScale) * 100;
  return clamp(Math.round(percentage), MIN_PET_SIZE_PERCENT, MAX_PET_SIZE_PERCENT);
}

export function petPercentToScale(percent: number, fitScale: number): number {
  const safeFitScale = isPositiveFinite(fitScale) ? fitScale : FALLBACK_FIT_SCALE;
  const safePercent = clamp(percent, MIN_PET_SIZE_PERCENT, MAX_PET_SIZE_PERCENT);
  return safeFitScale * (safePercent / 100);
}

export function rescalePetForFitChange(scale: number, previousFitScale: number, nextFitScale: number): number {
  const safePreviousFit = isPositiveFinite(previousFitScale) ? previousFitScale : FALLBACK_FIT_SCALE;
  const safeNextFit = isPositiveFinite(nextFitScale) ? nextFitScale : FALLBACK_FIT_SCALE;
  const relativeSize = clampPetScaleToFit(scale, safePreviousFit) / safePreviousFit;
  return clampPetScaleToFit(safeNextFit * relativeSize, safeNextFit);
}

/** Converts the safe absolute settings floor into the current relative slider floor. */
export function minimumPetSizePercent(fitScale: number): number {
  if (!isPositiveFinite(fitScale)) return MIN_PET_SIZE_PERCENT;
  return clamp(
    Math.ceil((MIN_PERSISTED_PET_SCALE / fitScale) * 100),
    MIN_PET_SIZE_PERCENT,
    MAX_PET_SIZE_PERCENT,
  );
}
