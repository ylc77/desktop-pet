import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requireUpdaterObject(configuration, label) {
  if (!isRecord(configuration.plugins)) {
    throw new Error(`${label}: plugins must be an object.`);
  }
  if (!("updater" in configuration.plugins)) {
    throw new Error(`${label}: plugins.updater is missing.`);
  }
  if (!isRecord(configuration.plugins.updater)) {
    throw new Error(`${label}: plugins.updater must be an object and must never be null.`);
  }
  return configuration.plugins.updater;
}

function requirePassiveWindowsMode(updater, label) {
  if (!isRecord(updater.windows) || updater.windows.installMode !== "passive") {
    throw new Error(`${label}: plugins.updater.windows.installMode must be passive.`);
  }
}

function rejectDangerousTransport(updater, label) {
  for (const property of [
    "dangerousInsecureTransportProtocol",
    "dangerousAcceptInvalidCerts",
    "dangerousAcceptInvalidHostnames",
  ]) {
    if (updater[property] === true) {
      throw new Error(`${label}: ${property} must not be enabled.`);
    }
  }
}

export function validateBaseUpdaterConfig(configuration, label = "base configuration") {
  const updater = requireUpdaterObject(configuration, label);
  requirePassiveWindowsMode(updater, label);
  rejectDangerousTransport(updater, label);
  if (typeof updater.pubkey !== "string" || updater.pubkey.trim() !== "") {
    throw new Error(`${label}: ordinary builds must use an empty updater pubkey.`);
  }
  if (!Array.isArray(updater.endpoints) || updater.endpoints.length !== 0) {
    throw new Error(`${label}: ordinary builds must use an empty updater endpoints array.`);
  }
  if (configuration.bundle?.createUpdaterArtifacts !== false) {
    throw new Error(`${label}: ordinary builds must not create updater artifacts.`);
  }
  return { configured: false, networkEnabled: false };
}

export function validateProductionUpdaterConfig(configuration, label = "production configuration") {
  const updater = requireUpdaterObject(configuration, label);
  requirePassiveWindowsMode(updater, label);
  rejectDangerousTransport(updater, label);
  if (typeof updater.pubkey !== "string" || updater.pubkey.trim() === "") {
    throw new Error(`${label}: production updater pubkey must contain the public key text.`);
  }
  if (/^[A-Za-z]:[\\/]|^\\\\|\.key(?:\.pub)?$/i.test(updater.pubkey.trim())) {
    throw new Error(`${label}: updater pubkey must contain key text, not a filesystem path.`);
  }
  if (!Array.isArray(updater.endpoints) || updater.endpoints.length === 0) {
    throw new Error(`${label}: production updater endpoints must not be empty.`);
  }
  for (const endpoint of updater.endpoints) {
    let parsed;
    try {
      parsed = new URL(endpoint);
    } catch {
      throw new Error(`${label}: updater endpoint is not a valid absolute URL.`);
    }
    if (parsed.protocol !== "https:" || parsed.username || parsed.password) {
      throw new Error(`${label}: production updater endpoints must use HTTPS without credentials.`);
    }
  }
  if (configuration.bundle?.createUpdaterArtifacts !== true) {
    throw new Error(`${label}: production updater builds must create updater artifacts.`);
  }
  return { configured: true, endpointCount: updater.endpoints.length };
}

function readConfiguration(path, label) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`${label}: cannot read valid JSON (${error instanceof Error ? error.name : "unknown error"}).`);
  }
}

function argumentValue(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

const invokedAsScript = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedAsScript) {
  try {
    const repositoryRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
    const basePath = resolve(argumentValue("--base-config") ?? resolve(repositoryRoot, "src-tauri", "tauri.conf.json"));
    const productionPath = resolve(
      argumentValue("--production-config") ?? resolve(repositoryRoot, "src-tauri", "tauri.updater.conf.json"),
    );
    validateBaseUpdaterConfig(readConfiguration(basePath, "base configuration"));
    validateProductionUpdaterConfig(readConfiguration(productionPath, "production configuration"));
    process.stdout.write("Updater configuration validation passed.\n");
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : "Updater configuration validation failed."}\n`);
    process.exitCode = 1;
  }
}
