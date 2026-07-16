import type { CharacterManifest } from "../character/types";

export function mirroredHitbox(hitbox: NonNullable<CharacterManifest["hitbox"]>, mirrored: boolean) {
  return mirrored ? { ...hitbox, x: 1 - hitbox.x - hitbox.width } : { ...hitbox };
}

export function anchorLayout(anchor: CharacterManifest["anchor"]) {
  const x = Number((-anchor.x * 100).toFixed(6));
  const y = Number(((1 - anchor.y) * 100).toFixed(6));
  return {
    left: "50%",
    bottom: "0",
    transform: `translate(${x}%, ${y}%)`,
  };
}
