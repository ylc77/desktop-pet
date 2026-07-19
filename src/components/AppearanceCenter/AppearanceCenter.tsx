import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  importCharacterPackage,
  loadCharacterCatalog,
  removeInstalledCharacter,
  type CharacterCatalogEntry,
  type CharacterSelectionChanged,
  type CharacterSelectionRequest,
} from "../../core/character/CharacterCatalog";
import { log } from "../../core/diagnostics/logger";
import { isTauriRuntime } from "../../core/window/windowController";

export interface AppearanceCenterApi {
  list: (signal?: AbortSignal) => Promise<CharacterCatalogEntry[]>;
  importPackage: () => Promise<CharacterCatalogEntry | null>;
  remove: (id: string) => Promise<void>;
  requestSelection: (selection: CharacterSelectionRequest) => Promise<void>;
  listenSelectionChanged: (handler: (change: CharacterSelectionChanged) => void) => Promise<() => void>;
  currentCharacterId: () => Promise<string>;
}

const browserPreviewSelectionListeners = new Set<(change: CharacterSelectionChanged) => void>();
let browserPreviewCurrentCharacterId = "_placeholder";

const defaultApi: AppearanceCenterApi = {
  list: loadCharacterCatalog,
  importPackage: importCharacterPackage,
  remove: removeInstalledCharacter,
  requestSelection: async (selection) => {
    if (!isTauriRuntime()) {
      browserPreviewCurrentCharacterId = selection.id;
      queueMicrotask(() => browserPreviewSelectionListeners.forEach((handler) => handler({
        id: selection.id,
        source: selection.source ?? "bundled",
        requestId: selection.requestId,
        ok: true,
      })));
      return;
    }
    await invoke("request_character_selection", {
      id: selection.id,
      source: selection.source,
      requestId: selection.requestId,
      expiresAtMs: selection.expiresAtMs,
    });
  },
  listenSelectionChanged: async (handler) => {
    if (!isTauriRuntime()) {
      browserPreviewSelectionListeners.add(handler);
      return () => { browserPreviewSelectionListeners.delete(handler); };
    }
    return listen<CharacterSelectionChanged>("character-selection-changed", (event) => handler(event.payload));
  },
  currentCharacterId: async () => isTauriRuntime()
    ? (await invoke<string | null>("get_selected_character_id")) ?? "_placeholder"
    : browserPreviewCurrentCharacterId,
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
  const [failedUrl, setFailedUrl] = useState<string | null>(null);
  const previewUrl = entry.previewUrl;
  if (!previewUrl || failedUrl === previewUrl) {
    return <div className="appearance-preview-empty" aria-label="没有预览图">暂无预览</div>;
  }
  return <img className="appearance-preview" src={previewUrl} alt={`${entry.name} 预览`} loading="lazy" decoding="async" onError={() => setFailedUrl(previewUrl)} />;
}

function ConfirmRemoveDialog({ entry, current, onCancel, onConfirm }: {
  entry: CharacterCatalogEntry;
  current: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  const dialogRef = useRef<HTMLDivElement>(null);
  const cancelRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    cancelRef.current?.focus();
  }, []);

  return (
    <div className="appearance-confirm-backdrop" onMouseDown={(event) => {
      if (event.target === event.currentTarget) onCancel();
    }}>
      <div
        ref={dialogRef}
        className="appearance-confirm-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="appearance-remove-title"
        aria-describedby="appearance-remove-description"
        onKeyDown={(event) => {
          if (event.key === "Escape") {
            event.preventDefault();
            onCancel();
            return;
          }
          if (event.key !== "Tab") return;
          const controls = Array.from(dialogRef.current?.querySelectorAll<HTMLButtonElement>("button:not(:disabled)") ?? []);
          if (controls.length === 0) return;
          const first = controls[0];
          const last = controls[controls.length - 1];
          if (event.shiftKey && document.activeElement === first) {
            event.preventDefault();
            last.focus();
          } else if (!event.shiftKey && document.activeElement === last) {
            event.preventDefault();
            first.focus();
          }
        }}
      >
        <h2 id="appearance-remove-title">删除角色</h2>
        <p id="appearance-remove-description">
          确定从本机删除“{entry.name}”吗？
          {current ? "当前正在使用此外观，删除前会先切换到安全的内置外观。" : "删除后需要重新导入才能再次使用。"}
        </p>
        <div className="appearance-card-actions">
          <button ref={cancelRef} type="button" onClick={onCancel}>取消</button>
          <button type="button" className="danger" onClick={onConfirm}>删除角色</button>
        </div>
      </div>
    </div>
  );
}

const DEFAULT_SELECTION_TIMEOUT_MS = 120_000;
const SELECTION_REQUEST_LIFETIME_MS = 110_000;

interface PendingRemoval {
  entry: CharacterCatalogEntry;
  current: boolean;
}

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
  const [pendingRemoval, setPendingRemoval] = useState<PendingRemoval | null>(null);
  const pendingRequestId = useRef<string | null>(null);
  const removalAfterSelection = useRef<CharacterCatalogEntry | null>(null);
  const selectionTimeout = useRef<number | null>(null);
  const removalTrigger = useRef<HTMLElement | null>(null);
  const localSectionHeading = useRef<HTMLHeadingElement>(null);
  const removalTransactionActive = useRef(false);
  const closeAfterRemoval = useRef(false);

  const finishRemovalTransaction = useCallback(() => {
    removalTransactionActive.current = false;
    if (!closeAfterRemoval.current || !isTauriRuntime()) return;
    closeAfterRemoval.current = false;
    void getCurrentWindow().destroy().catch((error) => log("warn", "删除流程结束后关闭外观中心失败", error));
  }, []);

  const restoreRemovalFocus = useCallback(() => {
    const target = removalTrigger.current;
    removalTrigger.current = null;
    window.setTimeout(() => {
      if (target?.isConnected && !(target instanceof HTMLButtonElement && target.disabled)) target.focus();
      else localSectionHeading.current?.focus();
    }, 0);
  }, []);

  const focusAfterRemoval = useCallback(() => {
    removalTrigger.current = null;
    window.setTimeout(() => localSectionHeading.current?.focus(), 0);
  }, []);

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
      const removal = removalAfterSelection.current;
      removalAfterSelection.current = null;
      setFeedback({
        kind: "error",
        text: removal
          ? "删除前切换内置外观超时，当前角色未删除。请重试或重新打开外观中心。"
          : "外观切换等待超时，已保留原外观。请重试或重新打开外观中心。",
      });
      if (removal) {
        restoreRemovalFocus();
        finishRemovalTransaction();
      }
    }, selectionTimeoutMs);
  }, [clearSelectionTimeout, finishRemovalTransaction, restoreRemovalFocus, selectionTimeoutMs]);

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

  const completeRemoval = useCallback(async (entry: CharacterCatalogEntry) => {
    try {
      await api.remove(entry.id);
      await refresh();
      setFeedback({ kind: "info", text: "本地角色已删除" });
      focusAfterRemoval();
    } catch (error) {
      setFeedback({ kind: "error", text: `删除失败：${messageOf(error)}` });
      restoreRemovalFocus();
    } finally {
      setBusy(null);
      finishRemovalTransaction();
    }
  }, [api, finishRemovalTransaction, focusAfterRemoval, refresh, restoreRemovalFocus]);

  useEffect(() => {
    if (!isTauriRuntime()) return;
    let disposed = false;
    let unlisten: (() => void) | undefined;
    const currentWindow = getCurrentWindow();
    void currentWindow.onCloseRequested((event) => {
      // Tauri automatically prevents native close while this listener exists.
      // Force destruction when no protected deletion transaction is active.
      event.preventDefault();
      if (!removalTransactionActive.current) {
        void currentWindow.destroy().catch((error) => log("warn", "关闭外观中心失败", error));
        return;
      }
      closeAfterRemoval.current = true;
      setFeedback({ kind: "info", text: "正在完成已确认的角色删除，完成后会关闭外观中心…" });
    }).then((dispose) => {
      if (disposed) dispose();
      else unlisten = dispose;
    }).catch((error) => log("warn", "注册外观中心关闭保护失败", error));
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    void refresh(controller.signal);
    let disposed = false;
    let unlisten: (() => void) | undefined;
    void api.listenSelectionChanged((change) => {
      if (!pendingRequestId.current || change.requestId !== pendingRequestId.current) return;
      clearSelectionTimeout();
      pendingRequestId.current = null;
      const removal = removalAfterSelection.current;
      removalAfterSelection.current = null;
      if (change.ok) {
        setCurrentId(change.id);
        if (removal) {
          setFeedback({ kind: "info", text: "已切换到安全的内置外观，正在删除本地角色…" });
          void completeRemoval(removal);
          return;
        }
        setFeedback({ kind: "info", text: "外观已更换" });
      } else {
        setFeedback({
          kind: "error",
          text: removal
            ? `删除前无法切换到内置外观，当前角色未删除：${change.error ?? "未知错误"}`
            : `切换失败，已保留原外观：${change.error ?? "未知错误"}`,
        });
        if (removal) {
          restoreRemovalFocus();
          finishRemovalTransaction();
        }
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
      removalTransactionActive.current = false;
      closeAfterRemoval.current = false;
      removalAfterSelection.current = null;
      unlisten?.();
    };
  }, [api, clearSelectionTimeout, completeRemoval, finishRemovalTransaction, refresh, restoreRemovalFocus]);

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
        removalAfterSelection.current = null;
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
    removalAfterSelection.current = null;
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

  const cancelRemoval = () => {
    setPendingRemoval(null);
    restoreRemovalFocus();
  };

  const requestRemoval = (entry: CharacterCatalogEntry) => {
    const current = entry.id === activeEntry?.id && entry.source === activeEntry.source;
    removalTrigger.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    setPendingRemoval({ entry, current });
  };

  const remove = async (entry: CharacterCatalogEntry) => {
    setPendingRemoval(null);
    localSectionHeading.current?.focus();
    removalTransactionActive.current = true;
    setBusy(`remove:${entry.id}`);
    setFeedback(null);
    const current = entry.id === activeEntry?.id && entry.source === activeEntry.source;
    if (!current) {
      await completeRemoval(entry);
      return;
    }

    const validBundled = entries.filter((candidate) => candidate.source === "bundled" && candidate.valid);
    const fallback = validBundled.find((candidate) => candidate.id === "_placeholder") ?? validBundled[0];
    if (!fallback) {
      setFeedback({ kind: "error", text: "没有可用的内置外观，当前角色未删除。请先修复内置角色资源。" });
      setBusy(null);
      restoreRemovalFocus();
      finishRemovalTransaction();
      return;
    }

    const requestId = createRequestId();
    const expiresAtMs = Date.now() + SELECTION_REQUEST_LIFETIME_MS;
    pendingRequestId.current = requestId;
    removalAfterSelection.current = entry;
    armSelectionTimeout(requestId);
    setBusy(`remove-switch:${entry.id}`);
    setFeedback({ kind: "info", text: `正在切换到 ${fallback.name}，确认安全后再删除…` });
    try {
      await api.requestSelection({ id: fallback.id, source: "bundled", requestId, expiresAtMs });
    } catch (error) {
      clearSelectionTimeout();
      pendingRequestId.current = null;
      removalAfterSelection.current = null;
      setBusy(null);
      setFeedback({ kind: "error", text: `删除前无法请求切换到内置外观，当前角色未删除：${messageOf(error)}` });
      restoreRemovalFocus();
      finishRemovalTransaction();
    }
  };

  const bundledEntries = entries.filter((entry) => entry.source === "bundled");
  const localEntries = entries.filter((entry) => entry.source === "local");
  const interactionBlocked = busy !== null || pendingRemoval !== null;

  const renderEntry = (entry: CharacterCatalogEntry) => {
    const current = entry.id === activeEntry?.id && entry.source === activeEntry.source;
    const selectBusy = busy === `select:${entry.source}:${entry.id}` || busy === `select:local:${entry.id}`;
    const deleteDescriptionId = `appearance-delete-description-${entry.source}-${entry.id}`;
    return (
      <article aria-label={`${entry.name} 外观`} className={`appearance-card ${current ? "current" : ""} ${entry.valid ? "" : "broken"}`} key={`${entry.source}:${entry.id}`}>
        <CharacterPreview entry={entry} />
        <div className="appearance-card-body">
          <div className="appearance-card-title"><h3>{entry.name}</h3><span className={`source-badge ${entry.source}`}>{entry.source === "bundled" ? "官方" : "本机私用"}</span></div>
          <dl><div><dt>作者</dt><dd>{entry.author}</dd></div><div><dt>版本</dt><dd>{entry.version}</dd></div><div><dt>许可</dt><dd>{entry.license}</dd></div></dl>
          {current && <p className="appearance-current">当前使用</p>}
          {!entry.valid && <div className="appearance-errors"><strong>资源损坏</strong>{entry.errors.map((error, index) => <p key={`${error}:${index}`}>{error}</p>)}</div>}
          <div className="appearance-card-actions">
            <button type="button" className="primary" disabled={!entry.valid || current || interactionBlocked} onClick={() => void select(entry)}>{selectBusy ? "正在验证…" : current ? "使用中" : "使用此外观"}</button>
            {entry.source === "local" && <button type="button" className="danger" disabled={interactionBlocked} aria-describedby={current ? deleteDescriptionId : undefined} onClick={() => requestRemoval(entry)}>删除</button>}
          </div>
          {entry.source === "local" && current && <p id={deleteDescriptionId} className="appearance-delete-note">删除前会先切换到安全的内置外观</p>}
        </div>
      </article>
    );
  };

  return (
    <>
      <main className="appearance-window-page" aria-busy={loading || busy !== null}>
        <header className="appearance-header">
          <div><p className="appearance-eyebrow">七酱桌宠</p><h1>外观中心</h1><p>选择已制作的角色。每套服装在首版中作为独立外观显示。</p><p className="appearance-legal">公开内置角色必须具有明确授权；本机私用导入内容由导入者负责。</p></div>
          <div className="appearance-toolbar">
            <button type="button" onClick={() => void refresh()} disabled={loading || interactionBlocked}>刷新</button>
            <button type="button" className="primary" onClick={() => void importPackage()} disabled={loading || interactionBlocked}>{busy === "import" ? "正在导入…" : "导入角色包"}</button>
          </div>
        </header>

        {feedback && <p role={feedback.kind === "error" ? "alert" : "status"} className={`appearance-feedback ${feedback.kind}`}>{feedback.text}</p>}
        {loading && entries.length === 0 ? <p className="appearance-loading" role="status">正在读取外观…</p> : (
          <div className="appearance-sections">
            <section className="appearance-current-section" aria-labelledby="appearance-current-heading">
              <h2 id="appearance-current-heading">当前角色</h2>
              {activeEntry ? (
                <div className="appearance-current-summary">
                  <strong>{activeEntry.name}</strong>
                  <span className={`source-badge ${activeEntry.source}`}>{activeEntry.source === "bundled" ? "官方" : "本机私用"}</span>
                  <span className="appearance-current">当前使用</span>
                  <span>版本 {activeEntry.version}</span>
                </div>
              ) : <p className="appearance-empty">当前角色信息暂不可用。</p>}
            </section>

            <section aria-labelledby="appearance-bundled-heading">
              <h2 id="appearance-bundled-heading">官方内置角色</h2>
              {bundledEntries.length > 0
                ? <div className="appearance-grid" aria-label="官方内置角色">{bundledEntries.map(renderEntry)}</div>
                : <p className="appearance-empty">暂无官方内置角色。</p>}
            </section>

            <section aria-labelledby="appearance-local-heading">
              <h2 id="appearance-local-heading" ref={localSectionHeading} tabIndex={-1}>本机私用角色</h2>
              {localEntries.length > 0
                ? <div className="appearance-grid" aria-label="本机私用角色">{localEntries.map(renderEntry)}</div>
                : <div className="appearance-empty"><p>尚无本机私用角色。</p><button type="button" className="primary" onClick={() => void importPackage()} disabled={interactionBlocked}>导入 .qipet</button></div>}
            </section>
          </div>
        )}
      </main>
      {pendingRemoval && <ConfirmRemoveDialog entry={pendingRemoval.entry} current={pendingRemoval.current} onCancel={cancelRemoval} onConfirm={() => void remove(pendingRemoval.entry)} />}
    </>
  );
}
