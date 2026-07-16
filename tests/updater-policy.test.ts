import { describe, expect, it } from "vitest";
import {
  AUTOMATIC_UPDATE_INTERVAL_MS,
  compareSemver,
  isVersionNewer,
  parseSemver,
  reconcilePendingUpdate,
  shouldRunAutomaticCheck,
  startupCheckDelayMs,
} from "../src/core/updater/updaterPolicy";

describe("updater policy", () => {
  it("parses release and prerelease SemVer", () => {
    expect(parseSemver("0.2.1-beta.1")?.prerelease).toEqual(["beta", "1"]);
    expect(parseSemver("v1.2.3+build.5")?.core).toEqual([1, 2, 3]);
  });

  it("rejects malformed or leading-zero versions", () => {
    expect(parseSemver("1.2")).toBeNull();
    expect(parseSemver("01.2.3")).toBeNull();
  });

  it("orders release core versions", () => {
    expect(compareSemver("0.2.1", "0.2.0")).toBe(1);
    expect(compareSemver("0.2.0", "0.2.1")).toBe(-1);
    expect(compareSemver("0.2.0", "0.2.0")).toBe(0);
  });

  it("orders prereleases according to SemVer", () => {
    expect(compareSemver("0.2.0-beta.2", "0.2.0-beta.1")).toBe(1);
    expect(compareSemver("0.2.0", "0.2.0-beta.9")).toBe(1);
    expect(compareSemver("0.2.0-beta.1", "0.2.0-beta.1.1")).toBe(-1);
    expect(compareSemver("0.2.0-beta.10", "0.2.0-beta.2")).toBe(1);
  });

  it("never treats equal or lower versions as updates", () => {
    expect(isVersionNewer("0.1.0", "0.1.0")).toBe(false);
    expect(isVersionNewer("0.0.9", "0.1.0")).toBe(false);
    expect(isVersionNewer("0.2.0-beta.1", "0.1.0")).toBe(true);
  });

  it("allows an automatic check when no timestamp exists", () => {
    expect(shouldRunAutomaticCheck(null, Date.UTC(2026, 0, 2))).toBe(true);
  });

  it("throttles automatic checks for 24 hours", () => {
    const now = Date.UTC(2026, 0, 2);
    expect(shouldRunAutomaticCheck(new Date(now - AUTOMATIC_UPDATE_INTERVAL_MS + 1).toISOString(), now)).toBe(false);
    expect(shouldRunAutomaticCheck(new Date(now - AUTOMATIC_UPDATE_INTERVAL_MS).toISOString(), now)).toBe(true);
  });

  it("recovers from an invalid stored timestamp", () => {
    expect(shouldRunAutomaticCheck("not-a-date", Date.now())).toBe(true);
  });

  it("uses a fixed 15 second startup delay", () => {
    expect(startupCheckDelayMs()).toBe(15_000);
  });

  it("clears a pending target only after the running version matches", () => {
    expect(reconcilePendingUpdate("0.2.0", "0.2.0", null)).toEqual({ status: "installed", version: "0.2.0" });
    expect(reconcilePendingUpdate("0.1.0", "0.2.0", null)).toEqual({
      status: "notInstalled",
      currentVersion: "0.1.0",
      targetVersion: "0.2.0",
      notify: true,
    });
  });

  it("reports the same unconfirmed target only once while preserving it", () => {
    expect(reconcilePendingUpdate("0.1.0", "0.2.0", "0.2.0")).toMatchObject({
      status: "notInstalled",
      targetVersion: "0.2.0",
      notify: false,
    });
    expect(reconcilePendingUpdate("0.1.0", null, "0.2.0")).toEqual({ status: "none" });
  });
});
