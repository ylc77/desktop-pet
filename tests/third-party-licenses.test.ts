import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import {
  selectReviewedLicense,
  validateAggregateStructure,
} from "../scripts/licenses/license-aggregate.mjs";

const root = resolve(import.meta.dirname, "..");
const aggregate = readFileSync(resolve(root, "THIRD_PARTY_LICENSES.txt"), "utf8");

describe("third-party license aggregate", () => {
  it("contains one uniquely identified record per locked production dependency", () => {
    const packageIds = [...aggregate.matchAll(/^Package-ID: (.+)$/gm)].map((match) => match[1]);
    expect(packageIds.length).toBeGreaterThan(500);
    expect(new Set(packageIds).size).toBe(packageIds.length);
    expect(aggregate.match(/^=== PACKAGE BEGIN ===$/gm)).toHaveLength(packageIds.length);
    expect(aggregate.match(/^=== PACKAGE END ===$/gm)).toHaveLength(packageIds.length);
  });

  it("records an explicit selected branch and content-addressed text for every package", () => {
    const records = aggregate.split("=== PACKAGE BEGIN ===").slice(1).map((value) => value.split("=== PACKAGE END ===", 1)[0]);
    for (const record of records) {
      expect(record).toMatch(/\nLicense-Expression: .+\n/);
      expect(record).toMatch(/\nSelected-License-Branch: .+\n/);
      expect(record).toMatch(/\nAuthors: .+\n/);
      expect(record).toMatch(/\nRepository: .+\n/);
      expect(record).toMatch(/\nSource: https?:\/\/.+\n/);
      expect(record).toMatch(/\nSelected-License-Text-Refs: .+=[a-f0-9]{64}/);
    }
  });

  it("pins and fully describes the five unmodified crates.io MPL packages", () => {
    const records = aggregate.split("=== PACKAGE BEGIN ===").slice(1).map((value) => value.split("=== PACKAGE END ===", 1)[0]);
    const mpl = records.filter((record) => record.includes("\nLicense-Expression: MPL-2.0\n"));
    expect(mpl).toHaveLength(5);
    for (const record of mpl) {
      expect(record).toMatch(/\nVersion: \d+\.\d+\.\d+[^\n]*\n/);
      expect(record).toMatch(/\nSource: https:\/\/crates\.io\/api\/v1\/crates\/.+\/download\n/);
      expect(record).toMatch(/\nLock-Checksum: [a-f0-9]{64}\n/);
      expect(record).toContain("\nModified: false\n");
      expect(record).toContain("\nPatched-Replaced-Or-Vendored: false\n");
    }
  });

  it("contains no machine-local path in generated metadata", () => {
    expect(aggregate).not.toMatch(/(?:^|[\s"'(=])(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\|\/(?:Users|home)\/[^/\s]+\/)|file:\/{2,}|\.cargo[\\/]registry|node_modules[\\/]/i);
  });

  it("contains the pinned canonical texts required by all reviewed expression families", () => {
    for (const id of [
      "MIT",
      "Apache-2.0",
      "MPL-2.0",
      "BSD-3-Clause",
      "ISC",
      "Zlib",
      "Unicode-3.0",
      "CDLA-Permissive-2.0",
      "LLVM-exception",
    ]) {
      expect(aggregate).toMatch(new RegExp(`Selected-License-Text-Refs: [^\\n]*${id}=[a-f0-9]{64}`));
    }
  });

  it("rejects unreviewed expressions and malformed aggregate variants", () => {
    expect(() => selectReviewedLicense("Unknown-Private-License")).toThrow(/Unreviewed license expression/);
    const packageCount = Number(aggregate.match(/^Package-Count: (\d+)$/m)?.[1]);
    const textCount = Number(aggregate.match(/^License-Text-Count: (\d+)$/m)?.[1]);
    const records = Array.from({ length: packageCount }, () => ({}));

    expect(() =>
      validateAggregateStructure(
        aggregate.replace("=== PACKAGE BEGIN ===\n", ""),
        records,
        textCount,
        root,
      ),
    ).toThrow(/omitted or extra package/);
    expect(() =>
      validateAggregateStructure(
        aggregate.replace(/Package-ID: ([^\n]+)\n([\s\S]*?)Package-ID: ([^\n]+)\n/, (_all, first, middle) =>
          `Package-ID: ${first}\n${middle}Package-ID: ${first}\n`,
        ),
        records,
        textCount,
        root,
      ),
    ).toThrow(/duplicate package/);
    expect(() =>
      validateAggregateStructure(
        aggregate.replace("Authors: ", "Authors: C:\\private\\"),
        records,
        textCount,
        root,
      ),
    ).toThrow(/local filesystem path/);
    expect(() =>
      validateAggregateStructure(
        aggregate.replace(/(=== LICENSE TEXT BEGIN [a-f0-9]{64} ===[\s\S]*?---\n)(.)/, "$1X"),
        records,
        textCount,
        root,
      ),
    ).toThrow(/missing or corrupt/);
  });
});
