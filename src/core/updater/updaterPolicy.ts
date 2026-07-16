const SEMVER_PATTERN = /^(?:v)?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;
export const AUTOMATIC_UPDATE_INTERVAL_MS = 24 * 60 * 60 * 1_000;
export const STARTUP_CHECK_DELAY_MS = 15_000;

interface ParsedSemver {
  core: [number, number, number];
  prerelease: string[];
}

export function parseSemver(value: string): ParsedSemver | null {
  const match = SEMVER_PATTERN.exec(value.trim());
  if (!match) return null;
  return {
    core: [Number(match[1]), Number(match[2]), Number(match[3])],
    prerelease: match[4]?.split(".") ?? [],
  };
}

function comparePrerelease(left: readonly string[], right: readonly string[]): number {
  if (left.length === 0 || right.length === 0) {
    if (left.length === right.length) return 0;
    return left.length === 0 ? 1 : -1;
  }
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const a = left[index];
    const b = right[index];
    if (a === undefined || b === undefined) return a === undefined ? -1 : 1;
    if (a === b) continue;
    const aNumeric = /^\d+$/.test(a);
    const bNumeric = /^\d+$/.test(b);
    if (aNumeric && bNumeric) return Number(a) < Number(b) ? -1 : 1;
    if (aNumeric !== bNumeric) return aNumeric ? -1 : 1;
    return a < b ? -1 : 1;
  }
  return 0;
}

export function compareSemver(left: string, right: string): number | null {
  const a = parseSemver(left);
  const b = parseSemver(right);
  if (!a || !b) return null;
  for (let index = 0; index < a.core.length; index += 1) {
    if (a.core[index] !== b.core[index]) return a.core[index] < b.core[index] ? -1 : 1;
  }
  return comparePrerelease(a.prerelease, b.prerelease);
}

export function isVersionNewer(candidate: string, current: string): boolean {
  return compareSemver(candidate, current) === 1;
}

export function shouldRunAutomaticCheck(lastCheckAt: string | null, nowMs = Date.now()): boolean {
  if (!lastCheckAt) return true;
  const previous = Date.parse(lastCheckAt);
  if (!Number.isFinite(previous)) return true;
  return nowMs - previous >= AUTOMATIC_UPDATE_INTERVAL_MS;
}

export function startupCheckDelayMs(): number {
  return STARTUP_CHECK_DELAY_MS;
}

export type PendingUpdateReconciliation =
  | { status: "none" }
  | { status: "installed"; version: string }
  | { status: "notInstalled"; currentVersion: string; targetVersion: string; notify: boolean };

export function reconcilePendingUpdate(
  currentVersion: string,
  pendingVersion: string | null,
  lastFailedVersion: string | null,
): PendingUpdateReconciliation {
  if (!pendingVersion) return { status: "none" };
  if (currentVersion === pendingVersion) return { status: "installed", version: currentVersion };
  return {
    status: "notInstalled",
    currentVersion,
    targetVersion: pendingVersion,
    notify: lastFailedVersion !== pendingVersion,
  };
}
