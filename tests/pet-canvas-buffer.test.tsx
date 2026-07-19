import { fireEvent, render } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { BufferedFrame, PetCanvas } from "../src/components/PetCanvas/PetCanvas";
import { DEFAULT_SETTINGS } from "../src/core/settings/settingsSchema";

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
});
