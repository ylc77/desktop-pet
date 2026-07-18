export const SPDX_LICENSE_LIST_VERSION: string;
export const AGGREGATE_FORMAT_VERSION: string;
export const defaultRoot: string;

export interface LicenseRecord {
  id: string;
  expression: string;
}

export function selectReviewedLicense(
  expression: string,
  packageId?: string,
): { branch: string; ids: string[] };

export function buildThirdPartyLicenseAggregate(root?: string): {
  output: string;
  records: LicenseRecord[];
  textCount: number;
};

export function validateAggregateStructure(
  output: string,
  expectedRecords: readonly unknown[],
  expectedTextCount: number,
  root?: string,
): void;
