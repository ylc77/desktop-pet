import { fireEvent, render } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { BufferedFrame } from "../src/components/PetCanvas/PetCanvas";

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
