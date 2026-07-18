import { act, cleanup, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  isRuntimeMotionPaused,
  REDUCED_MOTION_QUERY,
  usePrefersReducedMotion,
} from "../src/hooks/usePrefersReducedMotion";

function installMatchMedia(initial: boolean) {
  let matches = initial;
  const listeners = new Set<(event: MediaQueryListEvent) => void>();
  const media = {
    media: REDUCED_MOTION_QUERY,
    onchange: null,
    get matches() { return matches; },
    addEventListener: vi.fn((_type: string, listener: (event: MediaQueryListEvent) => void) => listeners.add(listener)),
    removeEventListener: vi.fn((_type: string, listener: (event: MediaQueryListEvent) => void) => listeners.delete(listener)),
    addListener: vi.fn((listener: (event: MediaQueryListEvent) => void) => listeners.add(listener)),
    removeListener: vi.fn((listener: (event: MediaQueryListEvent) => void) => listeners.delete(listener)),
    dispatchEvent: vi.fn(() => true),
  } as unknown as MediaQueryList;
  const matchMedia = vi.fn(() => media);
  vi.stubGlobal("matchMedia", matchMedia);
  return {
    media,
    matchMedia,
    set(value: boolean) {
      matches = value;
      const event = { matches: value, media: REDUCED_MOTION_QUERY } as MediaQueryListEvent;
      act(() => listeners.forEach((listener) => listener(event)));
    },
  };
}

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe("Windows reduced-motion preference", () => {
  it("tracks matchMedia changes without writing a persisted setting", () => {
    const controller = installMatchMedia(false);
    const { result, unmount } = renderHook(() => usePrefersReducedMotion());

    expect(controller.matchMedia).toHaveBeenCalledWith(REDUCED_MOTION_QUERY);
    expect(result.current).toBe(false);
    controller.set(true);
    expect(result.current).toBe(true);
    controller.set(false);
    expect(result.current).toBe(false);

    unmount();
    expect(controller.media.removeEventListener).toHaveBeenCalledWith("change", expect.any(Function));
  });

  it("treats the system preference as a runtime pause without overriding manual pause", () => {
    expect(isRuntimeMotionPaused(false, false)).toBe(false);
    expect(isRuntimeMotionPaused(false, true)).toBe(true);
    expect(isRuntimeMotionPaused(true, false)).toBe(true);
    expect(isRuntimeMotionPaused(true, true)).toBe(true);
  });

  it("keeps RunningApp wired to both frame playback and window movement", () => {
    const source = readFileSync(resolve(process.cwd(), "src/app/App.tsx"), "utf8");
    expect(source).toContain("paused: runtimeMotionPaused || updateSuspended");
    expect(source).toContain("runtimeMotionPaused || updateSuspended || !windowVisible, onMotionFacing");
  });
});
