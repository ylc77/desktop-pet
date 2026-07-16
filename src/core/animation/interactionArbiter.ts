export const DRAG_THRESHOLD = 6;
export const DOUBLE_CLICK_WINDOW_MS = 220;

export function exceedsDragThreshold(start: { x: number; y: number }, current: { x: number; y: number }, threshold = DRAG_THRESHOLD): boolean {
  return Math.hypot(current.x - start.x, current.y - start.y) >= threshold;
}

export class ClickArbiter {
  private pendingAt: number | null = null;

  release(at: number): "pending-click" | "double-click" {
    if (this.pendingAt !== null && at - this.pendingAt <= DOUBLE_CLICK_WINDOW_MS) {
      this.pendingAt = null;
      return "double-click";
    }
    this.pendingAt = at;
    return "pending-click";
  }

  consumePending(): boolean {
    if (this.pendingAt === null) return false;
    this.pendingAt = null;
    return true;
  }

  cancel(): void { this.pendingAt = null; }
  get hasPendingClick(): boolean { return this.pendingAt !== null; }
}
