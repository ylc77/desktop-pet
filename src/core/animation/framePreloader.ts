export function getFrameDelay(fps: number): number { return 1000 / Math.max(1, Math.min(60, fps)); }

export function nextFrameIndex(current: number, length: number, loop: boolean): { index: number; completed: boolean } {
  if (length <= 1) return { index: 0, completed: !loop };
  const next = current + 1;
  if (next < length) return { index: next, completed: false };
  return { index: loop ? 0 : length - 1, completed: !loop };
}

