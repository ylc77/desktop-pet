import { describe, expect, it, vi } from "vitest";
import { getLogs, log, sanitizeDiagnosticText } from "../src/core/diagnostics/logger";

describe("diagnostic logger", () => {
  it("redacts local and network paths from stored and console details", () => {
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);

    log("error", "读取 C:\\Users\\someone\\settings.json 失败", new Error("file:///C:/Users/someone/private/settings.json and \\\\server\\share\\secret.txt"));

    const latest = getLogs().at(-1);
    expect(latest?.message).toBe("读取 [local path] 失败");
    expect(latest?.details).toBe("[local path] and [network path]");
    expect(consoleSpy).toHaveBeenCalledWith("[error] 读取 [local path] 失败", "[local path] and [network path]");
    consoleSpy.mockRestore();
  });
  it("redacts URL queries, bearer tokens, signing variables and private keys", () => {
    expect(sanitizeDiagnosticText("https://updates.example.org/latest.json?token=secret")).toBe("https://updates.example.org/[redacted]");
    expect(sanitizeDiagnosticText("Bearer abc.def.ghi")).toBe("Bearer [redacted]");
    expect(sanitizeDiagnosticText("TAURI_SIGNING_PRIVATE_KEY_PASSWORD=hunter2")).toBe("TAURI_SIGNING_PRIVATE_KEY_PASSWORD=[redacted]");
    expect(sanitizeDiagnosticText("-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----")).toBe("[private key redacted]");
  });
});
