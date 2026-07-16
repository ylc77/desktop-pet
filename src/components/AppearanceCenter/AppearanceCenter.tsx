import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import {
  importCharacterPackage,
  loadCharacterCatalog,
  removeInstalledCharacter,
  type CharacterCatalogEntry,
  type CharacterSelectionChanged,
  type CharacterSelectionRequest,
} from "../../core/character/CharacterCatalog";
import { log } from "../../core/diagnostics/logger";

export interface AppearanceCenterApi {
  list: (signal?: AbortSignal) => Promise<CharacterCatalogEntry[]>;
  importPackage: () => Promise<CharacterCatalogEntry | null>;
  remove: (id: string) => Promise<void>;
  requestSelection: (selection: CharacterSelectionRequest) => Promise<void>;
  listenSelectionChanged: (handler: (change: CharacterSelectionChanged) => void) => Promise<() => void>;
  currentCharacterId: () => Promise<string>;
}

const defaultApi: AppearanceCenterApi = {
  list: loadCharacterCatalog,
  importPackage: importCharacterPackage,
  remove: removeInstalledCharacter,
  requestSelection: async (selection) => {
    await invoke("request_character_selection", {
      id: selection.id,
      source: selection.source,
      requestId: selection.requestId,
      expiresAtMs: selection.expiresAtMs,
    });
  },
  listenSelectionChanged: (handler) => listen<CharacterSelectionChanged>("character-selection-changed", (event) => handler(event.payload)),
  currentCharacterId: async () => (await invoke<string | null>("get_selected_character_id")) ?? "_placeholder",
};

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

let requestSequence = 0;
function createRequestId(): string {
  requestSequence += 1;
  return `appearance-${Date.now().toString(36)}-${requestSequence.toString(36)}`;
}

function CharacterPreview({ entry }: { entry: CharacterCatalogEntry }) {
  const [failed, setFailed] = useState(false);
  useEffect(() => setFailed(false), [entry.previewUrl]);
  if (!entry.previewUrl || failed) return <div className="appearance-preview-empty" aria-label="没有预览图">暂无预览</div>;
  return <img className="appearance-preview" src={entry.previewUrl} alt={`${entry.name} 预览`} loading="lazy" decoding="async" onError={() => setFailed(true)} />;
}

const DEFAULT_SELECTION_TIMEOUT_MS = 120_000;
const SELECTION_REQUEST_LIFETIME_MS = 110_000;

export function AppearanceCenter({
  api = defaultApi,
  selectionTimeoutMs = DEFAULT_SELECTION_TIMEOUT_MS,
}: {
  api?: AppearanceCenterApi;
  selectionTimeoutMs?: number;
}) {
  const [entries, setEntries] = useState<CharacterCatalogEntry[]>([]);
  const [currentId, setCurrentId] = useState("");
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [feedback, setFeedback] = useState<{ kind: "info" | "error"; text: string } | null>(null);
  const pendingRequestId = useRef<string | null>(null);
  const selectionTimeout = useRef<number | null>(null);

  const clearSelectionTimeout = useCallback(() => {
    if (selectionTimeout.current !== null) window.clearTimeout(selectionTimeout.current);
    selectionTimeout.current = null;
  }, []);

  const armSelectionTimeout = useCallback((requestId: string) => {
    clearSelectionTimeout();
    selectionTimeout.current = window.setTimeout(() => {
      if (pendingRequestId.current !== requestId) return;
      pendingRequestId.current = null;
      selectionTimeout.current = null;
      setBusy(null);
      setFeedback({ kind: "error", text: "外观切换等待超时，已保留原外观。请重试或重新打开外观中心。" });
    }, selectionTimeoutMs);
  }, [clearSelectionTimeout, selectionTimeoutMs]);

  const refresh = useCallback(async (signal?: AbortSignal) => {
    setLoading(true);
    try {
      const [catalog, selected] = await Promise.all([api.list(signal), api.currentCharacterId()]);
      if (signal?.aborted) return;
      setEntries(catalog);
      setCurrentId(selected);
      setFeedback(null);
    } catch (error) {
      if (!signal?.aborted) setFeedback({ kind: "error", text: `外观列表加载失败：${messageOf(error)}` });
    } finally {
      if (!signal?.aborted) setLoading(false);
    }
  }, [api]);

  useEffect(() => {
    const controller = new AbortController();
    void refresh(controller.signal);
    let disposed = false;
    let unlisten: (() => void) | undefined;
    void api.listenSelectionChanged((change) => {
      if (!pendingRequestId.current || change.requestId !== pendingRequestId.current) return;
      clearSelectionTimeout();
      pendingRequestId.current = null;
      if (change.ok) {
        setCurrentId(change.id);
        setFeedback({ kind: "info", text: "外观已更换" });
      } else {
        setFeedback({ kind: "error", text: `切换失败，已保留原外观：${change.error ?? "未知错误"}` });
      }
      setBusy(null);
    }).then((dispose) => {
      if (disposed) dispose();
      else unlisten = dispose;
    }).catch((error) => log("warn", "监听角色切换结果失败", error));
    return () => {
      disposed = true;
      controller.abort();
      clearSelectionTimeout();
      unlisten?.();
    };
  }, [api, clearSelectionTimeout, refresh]);

  const importPackage = async () => {
    setBusy("import");
    setFeedback(null);
    let waitingForReload = false;
    let importCompleted = false;
    try {
      const imported = await api.importPackage();
      if (!imported) {
        setFeedback({ kind: "info", text: "已取消导入" });
        return;
      }
      importCompleted = true;
      await refresh();
      if (imported.id === currentId && imported.valid) {
        waitingForReload = true;
        const requestId = createRequestId();
        const expiresAtMs = Date.now() + SELECTION_REQUEST_LIFETIME_MS;
        pendingRequestId.current = requestId;
        armSelectionTimeout(requestId);
        setBusy(`select:local:${imported.id}`);
        setFeedback({ kind: "info", text: `角色包已更新，正在验证并重新加载 ${imported.name}…` });
        await api.requestSelection({ id: imported.id, source: "local", requestId, expiresAtMs });
      } else {
        setFeedback({ kind: "info", text: "角色包导入完成" });
      }
    } catch (error) {
      waitingForReload = false;
      clearSelectionTimeout();
      pendingRequestId.current = null;
      setFeedback({ kind: "error", text: `${importCompleted ? "角色包已导入，但重新加载请求失败" : "导入失败"}：${messageOf(error)}` });
    } finally {
      if (!waitingForReload) setBusy(null);
    }
  };

  const select = async (entry: CharacterCatalogEntry) => {
    const requestId = createRequestId();
    const expiresAtMs = Date.now() + SELECTION_REQUEST_LIFETIME_MS;
    pendingRequestId.current = requestId;
    armSelectionTimeout(requestId);
    setBusy(`select:${entry.source}:${entry.id}`);
    setFeedback({ kind: "info", text: `正在验证 ${entry.name} 的全部资源…` });
    try {
      await api.requestSelection({ id: entry.id, source: entry.source, requestId, expiresAtMs });
    } catch (error) {
      clearSelectionTimeout();
      pendingRequestId.current = null;
      setBusy(null);
      setFeedback({ kind: "error", text: `无法请求切换：${messageOf(error)}` });
    }
  };

  const activeEntry = entries.find((entry) => entry.id === currentId && entry.valid);

  const remove = async (entry: CharacterCatalogEntry) => {
    const current = entry.id === activeEntry?.id && entry.source === activeEntry.source;
    if (current || !window.confirm(`确定从本机删除“${entry.name}”吗？`)) return;
    setBusy(`remove:${entry.id}`);
    setFeedback(null);
    try {
      await api.remove(entry.id);
      await refresh();
      setFeedback({ kind: "info", text: "本地角色已删除" });
    } catch (error) {
      setFeedback({ kind: "error", text: `删除失败：${messageOf(error)}` });
    } finally {
      setBusy(null);
    }
  };

  return (
    <main className="appearance-window-page">
      <header className="appearance-header">
        <div><p className="appearance-eyebrow">七酱桌宠</p><h1>外观中心</h1><p>选择已制作的角色。每套服装在首版中作为独立外观显示。</p><p className="appearance-legal">公开内置角色必须具有明确授权；本机私用导入内容由导入者负责。</p></div>
        <div className="appearance-toolbar">
          <button type="button" onClick={() => void refresh()} disabled={loading || busy !== null}>刷新</button>
          <button type="button" className="primary" onClick={() => void importPackage()} disabled={loading || busy !== null}>{busy === "import" ? "正在导入…" : "导入角色包"}</button>
        </div>
      </header>

      {feedback && <p role="status" className={`appearance-feedback ${feedback.kind}`}>{feedback.text}</p>}
      {loading && entries.length === 0 ? <p className="appearance-loading">正在读取外观…</p> : (
        <section className="appearance-grid" aria-label="可用外观">
          {entries.map((entry) => {
            const current = entry.id === activeEntry?.id && entry.source === activeEntry.source;
            const selectBusy = busy === `select:${entry.source}:${entry.id}`;
            return (
              <article aria-label={`${entry.name} 外观`} className={`appearance-card ${current ? "current" : ""} ${entry.valid ? "" : "broken"}`} key={`${entry.source}:${entry.id}`}>
                <CharacterPreview entry={entry} />
                <div className="appearance-card-body">
                  <div className="appearance-card-title"><h2>{entry.name}</h2><span className={`source-badge ${entry.source}`}>{entry.source === "bundled" ? "官方" : "本机私用"}</span></div>
                  <dl><div><dt>作者</dt><dd>{entry.author}</dd></div><div><dt>版本</dt><dd>{entry.version}</dd></div><div><dt>许可</dt><dd>{entry.license}</dd></div></dl>
                  {current && <p className="appearance-current">当前使用</p>}
                  {!entry.valid && <div className="appearance-errors"><strong>资源损坏</strong>{entry.errors.map((error, index) => <p key={`${error}:${index}`}>{error}</p>)}</div>}
                  <div className="appearance-card-actions">
                    <button type="button" className="primary" disabled={!entry.valid || current || busy !== null} onClick={() => void select(entry)}>{selectBusy ? "正在验证…" : current ? "使用中" : "使用此外观"}</button>
                    {entry.source === "local" && <button type="button" className="danger" disabled={current || busy !== null} title={current ? "当前使用的外观不能删除" : undefined} onClick={() => void remove(entry)}>删除</button>}
                  </div>
                </div>
              </article>
            );
          })}
          {!loading && entries.length === 0 && <p className="appearance-empty">尚无可用外观，请导入角色包。</p>}
        </section>
      )}
    </main>
  );
}
