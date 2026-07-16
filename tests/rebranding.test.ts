import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const root = resolve(import.meta.dirname, "..");
const config = JSON.parse(readFileSync(resolve(root, "src-tauri/tauri.conf.json"), "utf8"));
const packageJson = JSON.parse(readFileSync(resolve(root, "package.json"), "utf8"));

function filesUnder(directory: string): string[] {
  return readdirSync(directory).flatMap((name) => {
    const path = resolve(directory, name);
    return statSync(path).isDirectory() ? filesUnder(path) : [path];
  });
}

describe("application rebranding", () => {
  it("uses the approved public brand and executable name without changing the identifier", () => {
    expect(config.productName).toBe("七酱桌宠");
    expect(config.mainBinaryName).toBe("desktop_pet");
    expect(config.identifier).toBe("dev.deskpet.framework");
    expect(config.app.windows[0].title).toBe("七酱桌宠");
  });

  it("keeps the application version consistent across JavaScript, Tauri, and Cargo", () => {
    const cargo = readFileSync(resolve(root, "src-tauri/Cargo.toml"), "utf8");
    const cargoVersion = cargo.match(/^version\s*=\s*"([^"]+)"/m)?.[1];
    const semver = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;
    expect(packageJson.version).toMatch(semver);
    expect(config.version).toBe(packageJson.version);
    expect(cargoVersion).toBe(packageJson.version);
  });

  it("bundles all required Windows icon resources", () => {
    const required = ["icons/32x32.png", "icons/128x128.png", "icons/128x128@2x.png", "icons/icon.png", "icons/icon.ico"];
    for (const icon of required) {
      expect(config.bundle.icon).toContain(icon);
      expect(existsSync(resolve(root, "src-tauri", icon)), icon).toBe(true);
    }
    expect(config.bundle.windows.nsis.installerIcon).toBe("icons/icon.ico");
    expect([...readFileSync(resolve(root, "src-tauri/icons/icon.ico")).subarray(0, 4)]).toEqual([0, 0, 1, 0]);
  });

  it("uses the generated default icon for the system tray", () => {
    const rust = readFileSync(resolve(root, "src-tauri/src/lib.rs"), "utf8");
    expect(rust).toContain('.tooltip("七酱桌宠")');
    expect(rust).toContain("app.default_window_icon()");
  });

  it("keeps placeholder generation isolated from the approved application icon", () => {
    const generator = readFileSync(resolve(root, "scripts/generate-placeholder.mjs"), "utf8");
    expect(generator).not.toMatch(/src-tauri[\\/]icons/i);
    expect(generator).not.toContain("app-icon.png");
  });

  it("creates and verifies the public installer alias", () => {
    const manifest = readFileSync(resolve(root, "scripts/create-release-manifest.ps1"), "utf8");
    const verifier = readFileSync(resolve(root, "scripts/windows/verify-release-artifacts.ps1"), "utf8");
    const build = readFileSync(resolve(root, "scripts/build-release.ps1"), "utf8");
    expect(manifest).toContain("$script:PublicInstallerName");
    expect(manifest).toContain("publicInstallerFile");
    expect(manifest).toContain("publicInstallerSha256");
    expect(manifest).toContain("Public and versioned installer hashes do not match");
    expect(verifier).toContain("Public installer hash matches versioned installer");
    expect(build).toContain("scripts\\create-release-manifest.ps1");
  });

  it("does not hardcode the legacy brand outside the explicit compatibility file", () => {
    const files = filesUnder(resolve(root, "scripts/windows"))
      .filter((path) => path.endsWith(".ps1") && !path.endsWith("common.ps1"));
    for (const file of files) {
      const content = readFileSync(file, "utf8");
      expect(content, file).not.toMatch(/Desk Pet Framework|desk-pet-framework(?:\.exe)?/i);
    }
    const common = readFileSync(resolve(root, "scripts/windows/common.ps1"), "utf8");
    for (const line of common.split(/\r?\n/).filter((line) => /Desk Pet Framework|desk-pet-framework/i.test(line))) {
      expect(line).toMatch(/Legacy/);
    }
    for (const file of [
      "README.md",
      "docs/INSTALLATION.md",
      "docs/PRIVACY.md",
      "docs/PUBLIC_BETA_RELEASE_NOTES.md",
      "docs/SIGNING_AND_SMARTSCREEN.md",
      "docs/TROUBLESHOOTING.md",
      "docs/UNINSTALLATION.md",
      "public/characters/_placeholder/manifest.json",
    ]) {
      expect(readFileSync(resolve(root, file), "utf8"), file).not.toMatch(/Desk Pet Framework|desk-pet-framework(?:\.exe)?/i);
    }
  });

  it("does not embed this workstation path in release metadata code", () => {
    for (const file of ["scripts/create-release-manifest.ps1", "scripts/build-release.ps1", "src-tauri/tauri.conf.json"]) {
      expect(readFileSync(resolve(root, file), "utf8")).not.toMatch(/F:\\STAGE\\desk pet|C:\\Users\\77/i);
    }
  });
});
