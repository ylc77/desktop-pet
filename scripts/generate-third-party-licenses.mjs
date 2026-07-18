import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  buildThirdPartyLicenseAggregate,
  defaultRoot,
  validateAggregateStructure,
} from "./licenses/license-aggregate.mjs";

const result = buildThirdPartyLicenseAggregate(defaultRoot);
validateAggregateStructure(result.output, result.records, result.textCount, defaultRoot);
writeFileSync(resolve(defaultRoot, "THIRD_PARTY_LICENSES.txt"), result.output, "utf8");
console.log(
  `Generated THIRD_PARTY_LICENSES.txt: packages=${result.records.length}; unique texts=${result.textCount}.`,
);
