import { fireEvent, render } from "@testing-library/react";
import { useState } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { BufferedFrame, PetCanvas, resolveDragMovementState } from "../src/components/PetCanvas/PetCanvas";
import type { LoadedAnimation } from "../src/core/character/types";
import { DEFAULT_SETTINGS } from "../src/core/settings/settingsSchema";

const windowControllerMocks = vi.hoisted(() => ({
  beginManualWindowDrag: vi.fn((pointerStart: { x: number; y: number }) => Promise.resolve({
    pointerStart,
    windowStart: { x: 100, y: 200 },
  })),
  updateManualWindowDrag: vi.fn(() => Promise.resolve()),
  setPetInteractionRegion: vi.fn(() => Promise.resolve()),
}));

vi.mock("../src/core/window/windowController", async () => {
  const actual = await vi.importActual<typeof import("../src/core/window/windowController")>("../src/core/window/windowController");
  return {
    ...actual,
    beginManualWindowDrag: windowControllerMocks.beginManualWindowDrag,
    updateManualWindowDrag: windowControllerMocks.updateManualWindowDrag,
    setPetInteractionRegion: windowControllerMocks.setPetInteractionRegion,
  };
});

afterEach(() => {
  Reflect.deleteProperty(HTMLElement.prototype, "setPointerCapture");
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  windowControllerMocks.beginManualWindowDrag.mockClear();
  windowControllerMocks.updateManualWindowDrag.mockClear();
  windowControllerMocks.setPetInteractionRegion.mockClear();
});

function imageFor(container: HTMLElement, source: string): HTMLImageElement {
  const image = [...container.querySelectorAll("img")].find((candidate) => candidate.getAttribute("src") === source);
  if (!image) throw new Error(`Image not found: ${source}`);
  return image;
}

describe("BufferedFrame", () => {
  it("keeps the previous valid frame visible until the candidate loads", () => {
    const { container, rerender } = render(<BufferedFrame source="idle-1.png" dropShadow={false} onError={vi.fn()} />);
    rerender(<BufferedFrame source="idle-2.png" dropShadow={false} onError={vi.fn()} />);
    expect(container.querySelector("img.active")?.getAttribute("src")).toBe("idle-1.png");
    fireEvent.load(imageFor(container, "idle-2.png"));
    expect(container.querySelector("img.active")?.getAttribute("src")).toBe("idle-2.png");
  });

  it("reuses an already loaded slot when a two-frame loop returns to frame one", () => {
    const { container, rerender } = render(<BufferedFrame source="idle-1.png" dropShadow={false} onError={vi.fn()} />);
    fireEvent.load(imageFor(container, "idle-1.png"));
    rerender(<BufferedFrame source="idle-2.png" dropShadow={false} onError={vi.fn()} />);
    fireEvent.load(imageFor(container, "idle-2.png"));
    expect(container.querySelector("img.active")?.getAttribute("src")).toBe("idle-2.png");

    rerender(<BufferedFrame source="idle-1.png" dropShadow={false} onError={vi.fn()} />);
    expect(container.querySelector("img.active")?.getAttribute("src")).toBe("idle-1.png");
  });

  it("cancels an unloaded candidate when animation returns to the active frame", () => {
    const { container, rerender } = render(<BufferedFrame source="idle-1.png" dropShadow={false} onError={vi.fn()} />);
    fireEvent.load(imageFor(container, "idle-1.png"));
    rerender(<BufferedFrame source="idle-2.png" dropShadow={false} onError={vi.fn()} />);
    const lateCandidate = imageFor(container, "idle-2.png");

    rerender(<BufferedFrame source="idle-1.png" dropShadow={false} onError={vi.fn()} />);
    fireEvent.load(lateCandidate);

    expect(container.querySelector("img.active")?.getAttribute("src")).toBe("idle-1.png");
  });

  it("ignores a late error from a superseded candidate", () => {
    const onError = vi.fn();
    const { container, rerender } = render(<BufferedFrame source="idle-1.png" dropShadow={false} onError={onError} />);
    rerender(<BufferedFrame source="idle-2.png" dropShadow={false} onError={onError} />);
    const superseded = imageFor(container, "idle-2.png");
    rerender(<BufferedFrame source="idle-3.png" dropShadow={false} onError={onError} />);
    fireEvent.error(superseded);
    expect(onError).not.toHaveBeenCalled();
    fireEvent.error(imageFor(container, "idle-3.png"));
    expect(onError).toHaveBeenCalledTimes(1);
    expect(container.querySelector("img.active")?.getAttribute("src")).toBe("idle-1.png");
  });
});

describe("PetCanvas size limit", () => {
  it("makes the full window interactive while an overlay menu is open, then restores the pet hit area", () => {
    vi.spyOn(window, "requestAnimationFrame").mockImplementation((callback) => {
      callback(0);
      return 1;
    });
    vi.spyOn(window, "innerWidth", "get").mockReturnValue(420);
    vi.spyOn(window, "innerHeight", "get").mockReturnValue(420);
    vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockReturnValue({
      width: 200,
      height: 300,
      top: 50,
      right: 300,
      bottom: 350,
      left: 100,
      x: 100,
      y: 50,
      toJSON: () => ({}),
    });

    const props = {
      frame: "idle-1.png",
      animation: { state: "idle", path: "idle", fps: 6, loop: true, frames: ["idle-1.png"] } as LoadedAnimation,
      settings: { ...DEFAULT_SETTINGS, scale: 1 },
      frameSize: { width: 1024, height: 1024 },
      anchor: { x: 0.5, y: 0.900391 },
      viewport: { width: 420, height: 420 },
      characterName: "小幽",
      showDebugBounds: false,
      simulateMissingFrame: false,
      onState: vi.fn(() => true),
      onInputDiagnostic: vi.fn(),
      onContextMenu: vi.fn(),
      onFrameError: vi.fn(),
    };

    const { rerender } = render(<PetCanvas {...props} interactionOverlayActive={false} />);
    expect(windowControllerMocks.setPetInteractionRegion).toHaveBeenLastCalledWith({
      x: 0.21904761904761905,
      y: 0.1,
      width: 0.5142857142857142,
      height: 0.7523809523809524,
    });

    rerender(<PetCanvas {...props} interactionOverlayActive />);
    expect(windowControllerMocks.setPetInteractionRegion).toHaveBeenLastCalledWith(null);

    rerender(<PetCanvas {...props} interactionOverlayActive={false} />);
    expect(windowControllerMocks.setPetInteractionRegion).toHaveBeenLastCalledWith({
      x: 0.21904761904761905,
      y: 0.1,
      width: 0.5142857142857142,
      height: 0.7523809523809524,
    });
  });

  it("clamps the final animation scale to the logical pet viewport", () => {
    const { container } = render(<PetCanvas
      frame="idle-1.png"
      animation={{ state: "idle", path: "idle", fps: 6, loop: true, frames: ["idle-1.png"], scale: 1.2 }}
      settings={{ ...DEFAULT_SETTINGS, scale: 1 }}
      frameSize={{ width: 1024, height: 1024 }}
      anchor={{ x: 0.5, y: 0.900391 }}
      viewport={{ width: 420, height: 420 }}
      characterName="小幽"
      showDebugBounds={false}
      simulateMissingFrame={false}
      onState={vi.fn(() => true)}
      onInputDiagnostic={vi.fn()}
      onContextMenu={vi.fn()}
      onFrameError={vi.fn()}
    />);

    expect(container.querySelector<HTMLElement>(".pet-transform")?.style.transform)
      .toBe("scale(0.41015625) translate(0px, 0px)");
  });

  it("corrects direction while manually moving the window with the pressed pointer", async () => {
    class TestPointerEvent extends MouseEvent {
      pointerId: number;

      constructor(type: string, init: PointerEventInit = {}) {
        super(type, init);
        this.pointerId = init.pointerId ?? 0;
      }
    }
    vi.stubGlobal("PointerEvent", TestPointerEvent);
    const onState = vi.fn();
    const setPointerCapture = vi.fn();
    const pendingFrames: FrameRequestCallback[] = [];
    vi.spyOn(window, "requestAnimationFrame").mockImplementation((callback) => {
      pendingFrames.push(callback);
      return pendingFrames.length;
    });
    Object.defineProperty(HTMLElement.prototype, "setPointerCapture", {
      configurable: true,
      value: setPointerCapture,
    });

    function Harness() {
      const [state, setState] = useState<"idle" | "walk_left" | "walk_right" | "land">("idle");
      const source = state === "walk_right"
        ? "walk-right-1.png"
        : state === "walk_left"
          ? "walk-left-1.png"
          : `${state}-1.png`;
      return <PetCanvas
        frame={source}
        animation={{ state, path: state, fps: 8, loop: true, frames: [source] }}
        settings={{ ...DEFAULT_SETTINGS, scale: 1, facing: "left" }}
        frameSize={{ width: 1024, height: 1024 }}
        anchor={{ x: 0.5, y: 0.900391 }}
        viewport={{ width: 420, height: 420 }}
        characterName="小幽"
        interactions={{ drag: "drag", land: "land" }}
        dragMovementStates={{ left: "walk_left", right: "walk_right" }}
        dragMovementPreviews={{ left: "walk-left-preview.png", right: "walk-right-preview.png" }}
        showDebugBounds={false}
        simulateMissingFrame={false}
        onState={(nextState, reason, force) => {
          onState(nextState, reason, force);
          setState(nextState as typeof state);
          return true;
        }}
        onInputDiagnostic={vi.fn()}
        onContextMenu={vi.fn()}
        onFrameError={vi.fn()}
      />;
    }

    const { container } = render(<Harness />);
    const hitArea = container.querySelector<HTMLElement>(".pet-hit-area");
    expect(hitArea).not.toBeNull();
    pendingFrames.length = 0;

    fireEvent.pointerDown(hitArea!, { button: 0, pointerId: 7, clientX: 10, clientY: 10, screenX: 100, screenY: 100 });
    fireEvent.pointerMove(hitArea!, { pointerId: 7, clientX: 13, clientY: 10, screenX: 103, screenY: 100 });
    expect(onState).not.toHaveBeenCalled();

    fireEvent.pointerMove(hitArea!, { pointerId: 7, clientX: 10, clientY: 18, screenX: 100, screenY: 108 });
    expect(setPointerCapture).toHaveBeenCalledWith(7);
    expect(onState).toHaveBeenCalledWith("walk_left", "pointer-drag", true);
    expect(container.querySelector(".pet-drag-preview.active")?.getAttribute("src")).toBe("walk-left-preview.png");
    expect(windowControllerMocks.updateManualWindowDrag).not.toHaveBeenCalled();

    fireEvent.pointerMove(hitArea!, { pointerId: 7, clientX: 18, clientY: 18, screenX: 108, screenY: 108 });
    expect(onState).toHaveBeenCalledWith("walk_right", "pointer-drag", true);
    expect(container.querySelector(".pet-drag-preview.active")?.getAttribute("src")).toBe("walk-right-preview.png");
    expect(windowControllerMocks.updateManualWindowDrag).not.toHaveBeenCalled();

    for (let index = 0; index < 10 && pendingFrames.length > 0; index += 1) {
      pendingFrames.shift()?.(16 + index);
    }
    await vi.waitFor(() => expect(windowControllerMocks.updateManualWindowDrag).toHaveBeenCalledWith(
      { pointerStart: { x: 100, y: 100 }, windowStart: { x: 100, y: 200 } },
      { x: 108, y: 108 },
    ));

    fireEvent.pointerUp(hitArea!, { pointerId: 7 });
    expect(onState).toHaveBeenCalledWith("land", "pointer-release", true);
    expect(container.querySelector(".pet-drag-preview.active")).toBeNull();
  });
});

describe("directional drag movement", () => {
  const states = { left: "walk_left", right: "walk_right" } as const;

  it("selects the left and right floating actions from horizontal pointer movement", () => {
    expect(resolveDragMovementState(-8, "right", states, "drag")).toBe("walk_left");
    expect(resolveDragMovementState(8, "left", states, "drag")).toBe("walk_right");
  });

  it("uses the current facing for vertical movement and safely falls back when a direction is unavailable", () => {
    expect(resolveDragMovementState(0, "left", states, "drag")).toBe("walk_left");
    expect(resolveDragMovementState(-8, "right", { right: "walk_right" }, "drag")).toBe("drag");
  });
});
