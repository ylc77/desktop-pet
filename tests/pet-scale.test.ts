import { describe, expect, it } from "vitest";
import {
  clampPetScaleToFit,
  getPetFitScale,
  minimumPetSizePercent,
  petPercentToScale,
  petScaleToPercent,
  rescalePetForFitChange,
} from "../src/core/animation/petScale";

describe("pet display scale", () => {
  const xiaoyouFrame = { width: 1024, height: 1024 };
  const xiaoyouAnchor = { x: 0.5, y: 0.900391 };
  const defaultViewport = { width: 420, height: 420 };

  it("maps Xiaoyou's 100% size to the 420px pet viewport", () => {
    const fitScale = getPetFitScale(xiaoyouFrame, xiaoyouAnchor, defaultViewport);
    expect(fitScale).toBeCloseTo(420 / 1024, 10);
    expect(petPercentToScale(100, fitScale)).toBeCloseTo(420 / 1024, 10);
    expect(petPercentToScale(50, fitScale)).toBeCloseTo(210 / 1024, 10);
  });

  it("keeps existing absolute settings while presenting a bounded percentage", () => {
    const fitScale = getPetFitScale(xiaoyouFrame, xiaoyouAnchor, defaultViewport);
    expect(petScaleToPercent(0.2, fitScale)).toBe(49);
    expect(petScaleToPercent(0.5, fitScale)).toBe(100);
    expect(clampPetScaleToFit(0.5, fitScale)).toBeCloseTo(fitScale, 10);
    expect(minimumPetSizePercent(fitScale)).toBe(10);
  });

  it("accounts for asymmetric anchors instead of assuming a centered canvas", () => {
    const fitScale = getPetFitScale(
      { width: 800, height: 600 },
      { x: 0.25, y: 0.8 },
      { width: 400, height: 300 },
    );
    expect(fitScale).toBeCloseTo(1 / 3, 10);
  });

  it("recomputes the limit from logical viewport pixels without using DPI", () => {
    const previousFitScale = getPetFitScale(xiaoyouFrame, xiaoyouAnchor, defaultViewport);
    const nextFitScale = getPetFitScale(xiaoyouFrame, xiaoyouAnchor, { width: 220, height: 220 });
    expect(nextFitScale).toBeCloseTo(220 / 1024, 10);
    const resizedScale = rescalePetForFitChange(previousFitScale / 2, previousFitScale, nextFitScale);
    expect(resizedScale).toBeCloseTo(nextFitScale / 2, 10);
    expect(petScaleToPercent(resizedScale, nextFitScale)).toBe(50);
  });

  it("keeps animation-level enlargement inside the final limit", () => {
    const fitScale = getPetFitScale(xiaoyouFrame, xiaoyouAnchor, defaultViewport);
    expect(clampPetScaleToFit(fitScale * 1.2, fitScale)).toBeCloseTo(fitScale, 10);
  });

  it("keeps viewport rescaling within the persisted settings floor", () => {
    expect(rescalePetForFitChange(0.01, 4, 0.2)).toBe(0.01);
  });

  it("uses a safe fallback for invalid dimensions", () => {
    expect(getPetFitScale({ width: 0, height: 1024 }, xiaoyouAnchor, defaultViewport)).toBe(1);
    expect(getPetFitScale(xiaoyouFrame, xiaoyouAnchor, { width: Number.NaN, height: 420 })).toBe(1);
  });
});
