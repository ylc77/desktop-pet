import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  buildThirdPartyLicenseAggregate,
  defaultRoot,
  validateAggregateStructure,
} from "./licenses/license-aggregate.mjs";

const aggregatePath = resolve(defaultRoot, "THIRD_PARTY_LICENSES.txt");
let actual;
try {
  actual = readFileSync(aggregatePath, "utf8").replace(/^\uFEFF/, "").replace(/\r\n?/g, "\n");
} catch {
  throw new Error("THIRD_PARTY_LICENSES.txt is missing. Run npm run generate:licenses.");
}

const expected = buildThirdPartyLicenseAggregate(defaultRoot);
validateAggregateStructure(actual, expected.records, expected.textCount, defaultRoot);
if (actual !== expected.output) {
  throw new Error(
    "THIRD_PARTY_LICENSES.txt is stale or does not match the locked dependency set. Run npm run generate:licenses.",
  );
}

const tauriConfig = JSON.parse(readFileSync(resolve(defaultRoot, "src-tauri", "tauri.conf.json"), "utf8"));
if (tauriConfig.bundle?.resources?.["../THIRD_PARTY_LICENSES.txt"] !== "THIRD_PARTY_LICENSES.txt") {
  throw new Error("THIRD_PARTY_LICENSES.txt is not included in Tauri bundle.resources.");
}

const notices = readFileSync(resolve(defaultRoot, "THIRD_PARTY_NOTICES.md"), "utf8");
if (!notices.includes("THIRD_PARTY_LICENSES.txt") || !notices.includes("SPDX License List 3.28.0")) {
  throw new Error("THIRD_PARTY_NOTICES.md does not document the bundled aggregate and pinned SPDX source.");
}

const mplRecords = expected.records.filter((record) => record.expression === "MPL-2.0");
if (mplRecords.length !== 5) throw new Error(`Expected five reviewed MPL-2.0 packages, found ${mplRecords.length}.`);
for (const record of mplRecords) {
  if (
    !record.checksum.match(/^[a-f0-9]{64}$/) ||
    record.modified !== "false" ||
    record.override !== "false" ||
    record.source !==
      `https://crates.io/api/v1/crates/${encodeURIComponent(record.name)}/${encodeURIComponent(record.version)}/download`
  ) {
    throw new Error(`MPL-2.0 provenance is incomplete for ${record.id}.`);
  }
}

console.log(
  `Third-party licenses validated offline: packages=${expected.records.length}; unique texts=${expected.textCount}; MPL-2.0=${mplRecords.length}.`,
);
