export interface NormalizedPetInteractionRegion {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface ClientRectLike {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

export interface ViewportLike {
  width: number;
  height: number;
}

export const PET_INTERACTION_PADDING_PX = 8;

export function normalizePetInteractionRegion(
  rect: ClientRectLike,
  viewport: ViewportLike,
  padding = PET_INTERACTION_PADDING_PX,
): NormalizedPetInteractionRegion | null {
  const values = [rect.left, rect.top, rect.right, rect.bottom, viewport.width, viewport.height, padding];
  if (
    values.some((value) => !Number.isFinite(value))
    || viewport.width <= 0
    || viewport.height <= 0
    || padding < 0
    || rect.right <= rect.left
    || rect.bottom <= rect.top
  ) {
    return null;
  }

  const left = Math.max(0, Math.min(viewport.width, rect.left - padding));
  const top = Math.max(0, Math.min(viewport.height, rect.top - padding));
  const right = Math.max(left, Math.min(viewport.width, rect.right + padding));
  const bottom = Math.max(top, Math.min(viewport.height, rect.bottom + padding));

  if (right <= left || bottom <= top) return null;

  return {
    x: left / viewport.width,
    y: top / viewport.height,
    width: (right - left) / viewport.width,
    height: (bottom - top) / viewport.height,
  };
}

export function samePetInteractionRegion(
  left: NormalizedPetInteractionRegion | null,
  right: NormalizedPetInteractionRegion | null,
  tolerance = 0.0001,
): boolean {
  if (left === null || right === null) return left === right;
  return Math.abs(left.x - right.x) <= tolerance
    && Math.abs(left.y - right.y) <= tolerance
    && Math.abs(left.width - right.width) <= tolerance
    && Math.abs(left.height - right.height) <= tolerance;
}
