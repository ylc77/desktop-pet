export interface DecodedFrameResource {
  source: string;
  release: () => void;
}

export type FrameDecoder = (source: string, signal?: AbortSignal) => Promise<DecodedFrameResource>;

function abortError(): Error {
  const error = new Error("Frame decoding was aborted.");
  error.name = "AbortError";
  return error;
}

export const decodeBrowserFrame: FrameDecoder = (source, signal) => new Promise((resolve, reject) => {
  if (signal?.aborted) { reject(abortError()); return; }
  const image = new Image();
  image.decoding = "async";
  let settled = false;
  const timeout = globalThis.setTimeout(() => finish(new Error("Frame decoding timed out.")), 15_000);
  const cleanup = () => {
    globalThis.clearTimeout(timeout);
    image.onload = null;
    image.onerror = null;
    signal?.removeEventListener("abort", onAbort);
  };
  const finish = (error?: unknown) => {
    if (settled) return;
    settled = true;
    cleanup();
    if (error) {
      image.src = "";
      reject(error);
    } else {
      resolve({ source, release: () => { image.src = ""; } });
    }
  };
  const onAbort = () => finish(abortError());
  image.onerror = () => finish(new Error("Frame image could not be loaded."));
  image.onload = () => {
    if (typeof image.decode !== "function") finish();
  };
  signal?.addEventListener("abort", onAbort, { once: true });
  image.src = source;
  if (typeof image.decode === "function") void image.decode().then(() => finish(), finish);
});

export class DecodedFrameCache {
  private entries = new Map<string, DecodedFrameResource>();
  private disposed = false;

  constructor(private maximumEntries = 320, private decoder: FrameDecoder = decodeBrowserFrame) {}

  get size(): number { return this.entries.size; }

  async preload(sources: readonly string[], signal?: AbortSignal, concurrency = 6): Promise<{ loaded: Set<string>; failed: string[] }> {
    const unique = [...new Set(sources)];
    const loaded = new Set<string>();
    const failed: string[] = [];
    let cursor = 0;
    const worker = async () => {
      while (cursor < unique.length) {
        if (this.disposed || signal?.aborted) throw abortError();
        const source = unique[cursor++];
        try {
          const existing = this.entries.get(source);
          if (existing) {
            this.entries.delete(source);
            this.entries.set(source, existing);
            loaded.add(source);
            continue;
          }
          const resource = await this.decoder(source, signal);
          if (this.disposed || signal?.aborted) { resource.release(); throw abortError(); }
          this.entries.set(source, resource);
          loaded.add(source);
          this.trim();
        } catch (error) {
          if (signal?.aborted || (error instanceof Error && error.name === "AbortError")) throw error;
          failed.push(source);
        }
      }
    };
    await Promise.all(Array.from({ length: Math.min(Math.max(1, concurrency), Math.max(1, unique.length)) }, worker));
    return { loaded, failed };
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.entries.forEach((entry) => entry.release());
    this.entries.clear();
  }

  private trim(): void {
    while (this.entries.size > this.maximumEntries) {
      const oldest = this.entries.keys().next().value as string | undefined;
      if (!oldest) break;
      this.entries.get(oldest)?.release();
      this.entries.delete(oldest);
    }
  }
}
