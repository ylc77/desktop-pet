export type LogLevel = "debug" | "info" | "warn" | "error";
export interface LogEntry { at: string; level: LogLevel; message: string; details?: string }

const MAX_ENTRIES = 100;
const entries: LogEntry[] = [];
const listeners = new Set<(items: readonly LogEntry[]) => void>();

function redactLocalPaths(value: string): string {
  return value
    .replace(/file:\/{2,3}[a-z]:[\\/][^\s,;)\]]+/gi, "[local path]")
    .replace(/\\\\[^\\\s]+\\[^\s,;)\]]+/g, "[network path]")
    .replace(/\b[a-z]:[\\/][^\s,;)\]]+/gi, "[local path]");
}

export function log(level: LogLevel, message: string, error?: unknown): void {
  const details = error instanceof Error ? error.message : error === undefined ? undefined : String(error);
  const entry: LogEntry = {
    at: new Date().toISOString(),
    level,
    message: redactLocalPaths(message),
    details: details === undefined ? undefined : redactLocalPaths(details),
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
