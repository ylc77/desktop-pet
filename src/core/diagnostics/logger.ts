export type LogLevel = "debug" | "info" | "warn" | "error";
export interface LogEntry { at: string; level: LogLevel; message: string; details?: string }

const MAX_ENTRIES = 100;
const entries: LogEntry[] = [];
const listeners = new Set<(items: readonly LogEntry[]) => void>();

function redactUrls(value: string): string {
  return value.replace(/https?:\/\/[^\s,;)\]]+/gi, (candidate) => {
    try {
      const parsed = new URL(candidate);
      return `${parsed.protocol}//${parsed.host}/[redacted]`;
    } catch {
      return "[redacted url]";
    }
  });
}

export function sanitizeDiagnosticText(value: string): string {
  const withoutSecrets = value
    .replace(/-----BEGIN [^-\r\n]*PRIVATE KEY-----[\s\S]*?-----END [^-\r\n]*PRIVATE KEY-----/gi, "[private key redacted]")
    .replace(/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/gi, "Bearer [redacted]")
    .replace(/\b(TAURI_SIGNING_PRIVATE_KEY(?:_PASSWORD)?|password|passwd|access[_-]?token|api[_-]?key|secret)\s*[:=]\s*([^\s,;]+)/gi, "$1=[redacted]")
    .replace(/file:\/{2,3}[a-z]:[\\/][^\s,;)\]]+/gi, "[local path]")
    .replace(/\\\\[^\\\s]+\\[^\s,;)\]]+/g, "[network path]")
    .replace(/\b[a-z]:[\\/][^\s,;)\]]+/gi, "[local path]")
    .replace(/\b(?:Users|用户)\\[^\\\s]+/gi, "Users\\[user]");
  return redactUrls(withoutSecrets);
}

export function log(level: LogLevel, message: string, error?: unknown): void {
  const details = error instanceof Error ? error.message : error === undefined ? undefined : String(error);
  const entry: LogEntry = {
    at: new Date().toISOString(),
    level,
    message: sanitizeDiagnosticText(message),
    details: details === undefined ? undefined : sanitizeDiagnosticText(details),
  };
  entries.push(entry);
  if (entries.length > MAX_ENTRIES) entries.shift();
  listeners.forEach((listener) => listener([...entries]));
  const writer = level === "error" ? console.error : level === "warn" ? console.warn : console.log;
  writer(`[${level}] ${entry.message}`, entry.details ?? "");
}

export function getLogs(): readonly LogEntry[] { return [...entries]; }
export function subscribeLogs(listener: (items: readonly LogEntry[]) => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
