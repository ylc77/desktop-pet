import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const root = resolve(import.meta.dirname, "..");
const css = readFileSync(resolve(root, "src/styles.css"), "utf8");

function extractBlock(selector: string, startAt = 0): string {
  const selectorIndex = css.indexOf(selector, startAt);
  expect(selectorIndex, `Missing CSS selector: ${selector}`).toBeGreaterThanOrEqual(0);

  const openingBrace = css.indexOf("{", selectorIndex + selector.length);
  expect(openingBrace, `Missing opening brace for: ${selector}`).toBeGreaterThanOrEqual(0);

  let depth = 0;
  for (let index = openingBrace; index < css.length; index += 1) {
    if (css[index] === "{") depth += 1;
    if (css[index] === "}") depth -= 1;
    if (depth === 0) return css.slice(openingBrace + 1, index);
  }

  throw new Error(`Missing closing brace for: ${selector}`);
}

function parseTokens(block: string): Record<string, string> {
  return Object.fromEntries(
    [...block.matchAll(/--([a-z0-9-]+)\s*:\s*([^;]+);/gi)].map((match) => [match[1], match[2].trim()]),
  );
}

function relativeLuminance(color: string): number {
  expect(color, "Contrast tokens must use six-digit hex colors").toMatch(/^#[0-9a-f]{6}$/i);
  const channels = [1, 3, 5].map((offset) => Number.parseInt(color.slice(offset, offset + 2), 16) / 255);
  const linear = channels.map((channel) =>
    channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4,
  );
  return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

function contrastRatio(foreground: string, background: string): number {
  const foregroundLuminance = relativeLuminance(foreground);
  const backgroundLuminance = relativeLuminance(background);
  const lighter = Math.max(foregroundLuminance, backgroundLuminance);
  const darker = Math.min(foregroundLuminance, backgroundLuminance);
  return (lighter + 0.05) / (darker + 0.05);
}

function expectContrast(
  theme: string,
  tokens: Record<string, string>,
  foreground: string,
  background: string,
  minimum: number,
): void {
  const ratio = contrastRatio(tokens[foreground], tokens[background]);
  expect(
    ratio,
    `${theme}: --${foreground} on --${background} is ${ratio.toFixed(2)}:1; expected at least ${minimum}:1`,
  ).toBeGreaterThanOrEqual(minimum);
}

const lightTokens = parseTokens(extractBlock(":root"));
const darkTokens = parseTokens(extractBlock(':root[data-theme="dark"]'));
const automaticDarkTokens = parseTokens(extractBlock(':root:not([data-theme="light"])'));

describe("warm Fluent semantic token contrast", () => {
  it.each([
    ["light", lightTokens],
    ["dark", darkTokens],
    ["automatic dark", automaticDarkTokens],
  ] as const)("keeps compact brand and accent text readable in %s mode", (theme, tokens) => {
    expectContrast(theme, tokens, "brand-warm", "background", 4.5);
    expectContrast(theme, tokens, "brand-warm", "surface", 4.5);
    expectContrast(theme, tokens, "accent", "accent-subtle", 4.5);
  });

  it.each([
    ["light", lightTokens],
    ["dark", darkTokens],
    ["automatic dark", automaticDarkTokens],
  ] as const)("keeps form and interactive boundaries distinguishable in %s mode", (theme, tokens) => {
    expectContrast(theme, tokens, "border-strong", "surface-elevated", 3);
    expectContrast(theme, tokens, "border-strong", "surface-muted", 3);
  });

  it("keeps forced-colors mode mapped to system contrast colors", () => {
    const forcedColorsIndex = css.indexOf("@media (forced-colors: active)");
    expect(forcedColorsIndex).toBeGreaterThanOrEqual(0);
    const forcedColorsTokens = parseTokens(extractBlock(":root", forcedColorsIndex));

    expect(forcedColorsTokens["brand-warm"]).toBe("CanvasText");
    expect(forcedColorsTokens["border-strong"]).toBe("CanvasText");
    expect(forcedColorsTokens.accent).toBe("Highlight");
    expect(forcedColorsTokens["accent-subtle"]).toBe("Canvas");
  });
});
