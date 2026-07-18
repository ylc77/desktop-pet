import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  lstatSync,
  readFileSync,
  readdirSync,
  realpathSync,
} from "node:fs";
import { dirname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

export const SPDX_LICENSE_LIST_VERSION = "3.28.0";
export const AGGREGATE_FORMAT_VERSION = "1";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
export const defaultRoot = resolve(scriptDirectory, "..", "..");
const spdxCacheDirectory = resolve(scriptDirectory, `spdx-${SPDX_LICENSE_LIST_VERSION}`);
const spdxManifestPath = resolve(spdxCacheDirectory, "manifest.json");

const expressionChoices = new Map([
  ["0BSD OR MIT OR Apache-2.0", { branch: "MIT", ids: ["MIT"] }],
  ["Unlicense OR MIT", { branch: "MIT", ids: ["MIT"] }],
  ["BSD-3-Clause", { branch: "BSD-3-Clause", ids: ["BSD-3-Clause"] }],
  ["MIT OR Apache-2.0", { branch: "MIT", ids: ["MIT"] }],
  ["MIT/Apache-2.0", { branch: "MIT", ids: ["MIT"] }],
  ["Apache-2.0 OR MIT", { branch: "Apache-2.0", ids: ["Apache-2.0"] }],
  ["MIT", { branch: "MIT", ids: ["MIT"] }],
  ["BSD-3-Clause AND MIT", { branch: "BSD-3-Clause AND MIT", ids: ["BSD-3-Clause", "MIT"] }],
  ["BSD-3-Clause/MIT", { branch: "MIT", ids: ["MIT"] }],
  ["Zlib OR Apache-2.0 OR MIT", { branch: "Zlib", ids: ["Zlib"] }],
  ["Apache-2.0/MIT", { branch: "Apache-2.0", ids: ["Apache-2.0"] }],
  ["MPL-2.0", { branch: "MPL-2.0", ids: ["MPL-2.0"] }],
  ["Apache-2.0 AND MIT", { branch: "Apache-2.0 AND MIT", ids: ["Apache-2.0", "MIT"] }],
  ["CC0-1.0 OR MIT-0 OR Apache-2.0", { branch: "Apache-2.0", ids: ["Apache-2.0"] }],
  ["Apache-2.0 / MIT", { branch: "Apache-2.0", ids: ["Apache-2.0"] }],
  ["Zlib", { branch: "Zlib", ids: ["Zlib"] }],
  ["Apache-2.0 OR ISC OR MIT", { branch: "ISC", ids: ["ISC"] }],
  ["Unicode-3.0", { branch: "Unicode-3.0", ids: ["Unicode-3.0"] }],
  ["ISC", { branch: "ISC", ids: ["ISC"] }],
  [
    "Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT",
    {
      branch: "Apache-2.0 WITH LLVM-exception",
      ids: ["Apache-2.0", "LLVM-exception"],
    },
  ],
  ["MIT OR Zlib OR Apache-2.0", { branch: "Zlib", ids: ["Zlib"] }],
  ["BSD-3-Clause OR Apache-2.0", { branch: "BSD-3-Clause", ids: ["BSD-3-Clause"] }],
  [
    "BSD-3-Clause OR MIT OR Apache-2.0",
    { branch: "BSD-3-Clause", ids: ["BSD-3-Clause"] },
  ],
  ["MIT OR Apache-2.0 OR LGPL-2.1-or-later", { branch: "MIT", ids: ["MIT"] }],
  ["MIT OR Apache-2.0 OR Zlib", { branch: "Zlib", ids: ["Zlib"] }],
  ["Apache-2.0 AND ISC", { branch: "Apache-2.0 AND ISC", ids: ["Apache-2.0", "ISC"] }],
  ["Unlicense/MIT", { branch: "MIT", ids: ["MIT"] }],
  ["Apache-2.0", { branch: "Apache-2.0", ids: ["Apache-2.0"] }],
  [
    "Apache-2.0 WITH LLVM-exception",
    {
      branch: "Apache-2.0 WITH LLVM-exception",
      ids: ["Apache-2.0", "LLVM-exception"],
    },
  ],
  [
    "(MIT OR Apache-2.0) AND Unicode-3.0",
    { branch: "MIT AND Unicode-3.0", ids: ["MIT", "Unicode-3.0"] },
  ],
  ["CDLA-Permissive-2.0", { branch: "CDLA-Permissive-2.0", ids: ["CDLA-Permissive-2.0"] }],
]);

const expectedSpdxIds = [
  "Apache-2.0",
  "BSD-3-Clause",
  "CDLA-Permissive-2.0",
  "ISC",
  "LLVM-exception",
  "MIT",
  "MPL-2.0",
  "Unicode-3.0",
  "Zlib",
];

const normalizeText = (value) =>
  value
    .replace(/^\uFEFF/, "")
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((line) => line.trimEnd())
    .join("\n")
    .trimEnd() + "\n";
const sha256 = (value) => createHash("sha256").update(value).digest("hex");
const compareStrings = (left, right) => (left < right ? -1 : left > right ? 1 : 0);

function readJson(path, label) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`${label} is missing or invalid: ${error.message}`);
  }
}

function oneLine(value, fallback) {
  const text = Array.isArray(value)
    ? value.join("; ")
    : typeof value === "object" && value !== null
      ? value.name ?? JSON.stringify(value)
      : value;
  const normalized = String(text ?? "").replace(/\s+/g, " ").trim();
  return normalized || fallback;
}

function repositoryUrl(value) {
  const raw = typeof value === "string" ? value : value?.url;
  if (!raw) return "Not declared in package metadata";
  return oneLine(raw, "Not declared in package metadata").replace(/^git\+/, "").replace(/\.git$/, "");
}

function assertPublicMetadata(value, label, root) {
  const localPathPattern = /(?:^|[\s"'(=])(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\|\/(?:Users|home)\/[^/\s]+\/)|file:\/{2,}|\.cargo[\\/]registry|node_modules[\\/]/i;
  const rootText = resolve(root).replaceAll("/", "\\").toLowerCase();
  const normalized = String(value).replaceAll("/", "\\").toLowerCase();
  if (localPathPattern.test(value) || normalized.includes(rootText)) {
    throw new Error(`${label} contains a local filesystem path.`);
  }
}

function readCargoLockPackages(path) {
  const lock = readFileSync(path, "utf8").replace(/\r\n?/g, "\n");
  const result = new Map();
  const blocks = lock.matchAll(/\[\[package\]\]\n([\s\S]*?)(?=\n\[\[package\]\]|\s*$)/g);
  for (const match of blocks) {
    const block = match[1];
    const field = (name) => block.match(new RegExp(`^${name} = "([^"]*)"$`, "m"))?.[1];
    const name = field("name");
    const version = field("version");
    const source = field("source") ?? null;
    const checksum = field("checksum") ?? null;
    if (!name || !version) throw new Error("Cargo.lock contains a package without name or version.");
    const key = `${name}\u0000${version}\u0000${source ?? ""}`;
    if (result.has(key)) throw new Error(`Cargo.lock contains duplicate package ${name}@${version}.`);
    result.set(key, { name, version, source, checksum });
  }
  return result;
}

function isLicenseFile(name) {
  if (/\.(?:rs|c|cc|cpp|cxx|h|hpp|js|jsx|ts|tsx|py|go|java|kt|swift|toml|json|yaml|yml)$/i.test(name)) {
    return false;
  }
  return /^(?:license|licence|copying|notice|copyright)(?:$|[._-])/i.test(name);
}

function collectLicenseFiles(packageRoot) {
  const result = [];
  const visit = (directory) => {
    const entries = readdirSync(directory, { withFileTypes: true }).sort((left, right) =>
      compareStrings(left.name, right.name),
    );
    for (const entry of entries) {
      const path = resolve(directory, entry.name);
      const relativePath = relative(packageRoot, path).split(sep).join("/");
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory()) {
        if (![".git", "node_modules", "target"].includes(entry.name)) visit(path);
        continue;
      }
      if (!entry.isFile() || !isLicenseFile(entry.name)) continue;
      const stat = lstatSync(path);
      if (stat.size > 2 * 1024 * 1024) throw new Error(`License file is unexpectedly large: ${relativePath}`);
      const bytes = readFileSync(path);
      if (bytes.includes(0)) throw new Error(`License file is not UTF-8 text: ${relativePath}`);
      result.push({ path: relativePath, text: normalizeText(bytes.toString("utf8")) });
    }
  };
  visit(packageRoot);
  return result;
}

function loadSpdxCache() {
  const manifest = readJson(spdxManifestPath, "SPDX cache manifest");
  if (manifest.licenseListVersion !== SPDX_LICENSE_LIST_VERSION) {
    throw new Error(`SPDX cache version must be ${SPDX_LICENSE_LIST_VERSION}.`);
  }
  const ids = Object.keys(manifest.files ?? {}).sort();
  if (JSON.stringify(ids) !== JSON.stringify(expectedSpdxIds)) {
    throw new Error("SPDX cache manifest does not contain the exact reviewed identifier set.");
  }
  const result = new Map();
  for (const id of ids) {
    const file = resolve(spdxCacheDirectory, `${id}.txt`);
    if (!existsSync(file)) throw new Error(`SPDX cache text is missing for ${id}.`);
    const text = normalizeText(readFileSync(file, "utf8"));
    const actualHash = sha256(text);
    if (manifest.files[id] !== actualHash) throw new Error(`SPDX cache hash mismatch for ${id}.`);
    if (text.trim().length < 100) throw new Error(`SPDX cache text is incomplete for ${id}.`);
    result.set(id, { text, hash: actualHash });
  }
  return result;
}

export function selectReviewedLicense(expression, packageId = "test:package") {
  const selected = expressionChoices.get(expression);
  if (!selected) {
    throw new Error(`Unreviewed license expression for ${packageId}: ${expression || "<missing>"}.`);
  }
  return selected;
}

function cargoMetadata(root) {
  try {
    return JSON.parse(
      execFileSync(
        "cargo",
        [
          "metadata",
          "--manifest-path",
          "src-tauri/Cargo.toml",
          "--locked",
          "--offline",
          "--format-version",
          "1",
        ],
        {
          cwd: root,
          encoding: "utf8",
          stdio: ["ignore", "pipe", "pipe"],
          maxBuffer: 64 * 1024 * 1024,
        },
      ),
    );
  } catch {
    throw new Error("Unable to inspect locked Cargo dependency licenses in offline mode.");
  }
}

function verifyCargoArchiveChecksum(manifestPath, name, version, expectedChecksum) {
  const marker = `${sep}registry${sep}src${sep}`;
  const markerIndex = manifestPath.indexOf(marker);
  if (markerIndex < 0) {
    throw new Error(`Unable to locate the cached crates.io archive for cargo:${name}@${version}.`);
  }
  const cargoHome = manifestPath.slice(0, markerIndex);
  const sourceRelative = manifestPath.slice(markerIndex + marker.length);
  const registryDirectory = sourceRelative.split(sep)[0];
  const archive = resolve(
    cargoHome,
    "registry",
    "cache",
    registryDirectory,
    `${name}-${version}.crate`,
  );
  if (!existsSync(archive)) {
    throw new Error(`Cached archive is missing for cargo:${name}@${version}; run cargo fetch before offline generation.`);
  }
  const actualChecksum = sha256(readFileSync(archive));
  if (actualChecksum !== expectedChecksum) {
    throw new Error(`Cached archive checksum does not match Cargo.lock for cargo:${name}@${version}.`);
  }
}

function assertNoCargoOverrides(root, metadataPackages) {
  const cargoToml = readFileSync(resolve(root, "src-tauri", "Cargo.toml"), "utf8");
  if (/^\s*\[(?:patch\.|replace\])/m.test(cargoToml)) {
    throw new Error("Cargo patch/replace overrides require a new third-party license review.");
  }
  for (const candidate of [
    resolve(root, ".cargo", "config"),
    resolve(root, ".cargo", "config.toml"),
    resolve(root, "src-tauri", ".cargo", "config"),
    resolve(root, "src-tauri", ".cargo", "config.toml"),
  ]) {
    if (!existsSync(candidate)) continue;
    const config = readFileSync(candidate, "utf8");
    if (/replace-with|vendored-sources|directory\s*=/i.test(config)) {
      throw new Error("Cargo source replacement/vendor overrides require a new third-party license review.");
    }
  }
  for (const entry of metadataPackages) {
    if (entry.license === "MPL-2.0" && entry.source !== "registry+https://github.com/rust-lang/crates.io-index") {
      throw new Error(`MPL dependency ${entry.name}@${entry.version} is not the reviewed crates.io source.`);
    }
  }
}

function npmRecords(root, packageLock, texts, spdx) {
  const records = [];
  for (const [lockPath, lockEntry] of Object.entries(packageLock.packages ?? {})) {
    if (!lockPath.startsWith("node_modules/") || lockEntry.dev === true) continue;
    const packageRoot = resolve(root, ...lockPath.split("/"));
    const manifest = readJson(resolve(packageRoot, "package.json"), `${lockPath}/package.json`);
    const name = oneLine(manifest.name, lockPath.slice("node_modules/".length));
    const version = oneLine(lockEntry.version ?? manifest.version, "");
    const id = `npm:${name}@${version}`;
    if (!version) throw new Error(`${id} has no locked version.`);
    const expression = oneLine(lockEntry.license ?? manifest.license, "");
    const selected = selectReviewedLicense(expression, id);
    const originals = collectLicenseFiles(realpathSync(packageRoot));
    const packageTexts = originals.map((entry) => {
      const hash = sha256(entry.text);
      if (!texts.has(hash)) texts.set(hash, { origin: `package:${id}/${entry.path}`, text: entry.text });
      return `${entry.path}=${hash}`;
    });
    const canonical = selected.ids.map((licenseId) => {
      const cached = spdx.get(licenseId);
      if (!cached) throw new Error(`${id} selects an uncached SPDX identifier: ${licenseId}.`);
      if (!texts.has(cached.hash)) texts.set(cached.hash, { origin: `spdx:${licenseId}`, text: cached.text });
      return `${licenseId}=${cached.hash}`;
    });
    const record = {
      id,
      ecosystem: "npm",
      name,
      version,
      expression,
      selectedBranch: selected.branch,
      authors: oneLine(manifest.author ?? manifest.authors, "Not declared in package metadata"),
      repository: repositoryUrl(manifest.repository),
      source: oneLine(lockEntry.resolved, "Not declared in lock file"),
      checksum: oneLine(lockEntry.integrity, "Not declared in lock file"),
      modified: "false",
      override: "false",
      packageTexts,
      canonical,
    };
    for (const [key, value] of Object.entries(record)) {
      if (typeof value === "string") assertPublicMetadata(value, `${id} ${key}`, root);
    }
    records.push(record);
  }
  return records;
}

function cargoRecords(root, metadata, cargoLock, texts, spdx) {
  const records = [];
  const sourcedPackages = metadata.packages.filter((entry) => entry.source !== null);
  const metadataKeys = new Set(
    sourcedPackages.map((entry) => `${entry.name}\u0000${entry.version}\u0000${entry.source}`),
  );
  const lockedSourcedKeys = [...cargoLock.entries()]
    .filter(([, entry]) => entry.source !== null)
    .map(([key]) => key);
  if (
    lockedSourcedKeys.length !== metadataKeys.size ||
    lockedSourcedKeys.some((key) => !metadataKeys.has(key))
  ) {
    throw new Error("Cargo metadata does not exactly cover every sourced package in Cargo.lock.");
  }
  assertNoCargoOverrides(root, sourcedPackages);
  for (const entry of sourcedPackages) {
    const key = `${entry.name}\u0000${entry.version}\u0000${entry.source}`;
    const locked = cargoLock.get(key);
    const id = `cargo:${entry.name}@${entry.version}`;
    if (!locked?.checksum) throw new Error(`${id} has no matching Cargo.lock checksum.`);
    verifyCargoArchiveChecksum(entry.manifest_path, entry.name, entry.version, locked.checksum);
    const expression = oneLine(entry.license, "");
    const selected = selectReviewedLicense(expression, id);
    const packageRoot = realpathSync(dirname(entry.manifest_path));
    const originals = collectLicenseFiles(packageRoot);
    const packageTexts = originals.map((license) => {
      const hash = sha256(license.text);
      if (!texts.has(hash)) texts.set(hash, { origin: `package:${id}/${license.path}`, text: license.text });
      return `${license.path}=${hash}`;
    });
    const canonical = selected.ids.map((licenseId) => {
      const cached = spdx.get(licenseId);
      if (!cached) throw new Error(`${id} selects an uncached SPDX identifier: ${licenseId}.`);
      if (!texts.has(cached.hash)) texts.set(cached.hash, { origin: `spdx:${licenseId}`, text: cached.text });
      return `${licenseId}=${cached.hash}`;
    });
    const record = {
      id,
      ecosystem: "cargo",
      name: entry.name,
      version: entry.version,
      expression,
      selectedBranch: selected.branch,
      authors: oneLine(entry.authors, "Not declared in package metadata"),
      repository: repositoryUrl(entry.repository),
      source: `https://crates.io/api/v1/crates/${encodeURIComponent(entry.name)}/${encodeURIComponent(entry.version)}/download`,
      checksum: locked.checksum,
      modified: "false",
      override: "false",
      packageTexts,
      canonical,
    };
    for (const [field, value] of Object.entries(record)) {
      if (typeof value === "string") assertPublicMetadata(value, `${id} ${field}`, root);
    }
    records.push(record);
  }
  return records;
}

function renderRecord(record) {
  return [
    "=== PACKAGE BEGIN ===",
    `Package-ID: ${record.id}`,
    `Ecosystem: ${record.ecosystem}`,
    `Name: ${record.name}`,
    `Version: ${record.version}`,
    `License-Expression: ${record.expression}`,
    `Selected-License-Branch: ${record.selectedBranch}`,
    `Authors: ${record.authors}`,
    `Repository: ${record.repository}`,
    `Source: ${record.source}`,
    `Lock-Checksum: ${record.checksum}`,
    `Modified: ${record.modified}`,
    `Patched-Replaced-Or-Vendored: ${record.override}`,
    `Package-License-Files: ${record.packageTexts.length > 0 ? record.packageTexts.join("; ") : "none; using pinned SPDX text"}`,
    `Selected-License-Text-Refs: ${record.canonical.join("; ")}`,
    "=== PACKAGE END ===",
  ].join("\n");
}

export function buildThirdPartyLicenseAggregate(root = defaultRoot) {
  const packageLockPath = resolve(root, "package-lock.json");
  const cargoLockPath = resolve(root, "src-tauri", "Cargo.lock");
  const packageLockText = normalizeText(readFileSync(packageLockPath, "utf8"));
  const cargoLockText = normalizeText(readFileSync(cargoLockPath, "utf8"));
  const packageLock = JSON.parse(packageLockText);
  const cargoLock = readCargoLockPackages(cargoLockPath);
  const metadata = cargoMetadata(root);
  const spdx = loadSpdxCache();
  const texts = new Map();
  const records = [
    ...npmRecords(root, packageLock, texts, spdx),
    ...cargoRecords(root, metadata, cargoLock, texts, spdx),
  ].sort((left, right) => compareStrings(left.id, right.id));

  const ids = records.map((record) => record.id);
  if (new Set(ids).size !== ids.length) throw new Error("Dependency set contains duplicate package identities.");

  const textSections = [...texts.entries()]
    .sort(([left], [right]) => compareStrings(left, right))
    .map(
      ([hash, value]) =>
        [
          `=== LICENSE TEXT BEGIN ${hash} ===`,
          `Text-SHA256: ${hash}`,
          `First-Origin: ${value.origin}`,
          "---",
          value.text.trimEnd(),
          `=== LICENSE TEXT END ${hash} ===`,
        ].join("\n"),
    );

  const output = [
    "Qijiang Desktop Pet - Third-Party Licenses",
    `Aggregate-Format-Version: ${AGGREGATE_FORMAT_VERSION}`,
    `SPDX-License-List-Version: ${SPDX_LICENSE_LIST_VERSION}`,
    `Package-Lock-SHA256: ${sha256(packageLockText)}`,
    `Cargo-Lock-SHA256: ${sha256(cargoLockText)}`,
    `Package-Count: ${records.length}`,
    `License-Text-Count: ${texts.size}`,
    "",
    "This file is generated deterministically from package-lock.json, src-tauri/Cargo.lock,",
    "the installed locked package contents, and the repository's pinned SPDX text cache.",
    "Each package appears exactly once. Package license/notice texts are content-addressed and",
    "deduplicated. Selected-License-Branch records the reviewed distributable branch.",
    "",
    ...records.flatMap((record) => [renderRecord(record), ""]),
    ...textSections.flatMap((section) => [section, ""]),
  ].join("\n");

  assertPublicMetadata(output, "Aggregate", root);
  return { output: normalizeText(output), records, textCount: texts.size };
}

export function validateAggregateStructure(output, expectedRecords, expectedTextCount, root = defaultRoot) {
  if (!output.startsWith("Qijiang Desktop Pet - Third-Party Licenses\n")) {
    throw new Error("Third-party license aggregate header is missing.");
  }
  const packageBegins = [...output.matchAll(/^=== PACKAGE BEGIN ===$/gm)].length;
  const packageEnds = [...output.matchAll(/^=== PACKAGE END ===$/gm)].length;
  const packageIds = [...output.matchAll(/^Package-ID: (.+)$/gm)].map((match) => match[1]);
  const textBegins = [...output.matchAll(/^=== LICENSE TEXT BEGIN ([a-f0-9]{64}) ===$/gm)].map((match) => match[1]);
  const textEnds = [...output.matchAll(/^=== LICENSE TEXT END ([a-f0-9]{64}) ===$/gm)].map((match) => match[1]);
  if (packageBegins !== expectedRecords.length || packageEnds !== expectedRecords.length) {
    throw new Error("Third-party license aggregate has an omitted or extra package record.");
  }
  if (new Set(packageIds).size !== packageIds.length) {
    throw new Error("Third-party license aggregate has duplicate package records.");
  }
  if (textBegins.length !== expectedTextCount || textEnds.length !== expectedTextCount) {
    throw new Error("Third-party license aggregate has an omitted or extra license text.");
  }
  if (new Set(textBegins).size !== textBegins.length || textBegins.some((hash, index) => textEnds[index] !== hash)) {
    throw new Error("Third-party license aggregate has duplicate or mismatched license text sections.");
  }
  for (const hash of textBegins) {
    const escaped = hash.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const match = output.match(
      new RegExp(`=== LICENSE TEXT BEGIN ${escaped} ===\\nText-SHA256: ${escaped}\\nFirst-Origin: [^\\n]+\\n---\\n([\\s\\S]*?)\\n=== LICENSE TEXT END ${escaped} ===`),
    );
    if (!match || sha256(normalizeText(match[1])) !== hash) {
      throw new Error(`Third-party license text body is missing or corrupt: ${hash}.`);
    }
  }
  assertPublicMetadata(output, "Aggregate", root);
}
