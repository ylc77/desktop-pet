import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  BrowserPreviewSettingsClient,
  SettingsWindowClient,
  isSettingsSectionId,
  type DesktopControlAction,
  type DesktopControlSnapshot,
  type SettingsSectionId,
  type SettingsWindowClientLike,
} from "../../core/desktopControl";
import { isTauriRuntime } from "../../core/window/windowController";
import type { AppSettings } from "../../core/settings/settingsSchema";
import { log } from "../../core/diagnostics/logger";
import { ConfirmDialog, InlineAlert, SettingsNavigation, WindowHeader } from "../ui";
import {
  AboutSettingsPage,
  AppearanceSettingsPage,
  BehaviorSettingsPage,
  GeneralSettingsPage,
  UpdateSettingsPage,
} from "./SettingsPages";

interface Props {
  client?: SettingsWindowClientLike;
  onClose?: () => void;
}

type Feedback = { tone: "info" | "success" | "warning" | "danger"; message: string };

function initialSectionFromLocation(): SettingsSectionId {
  const requested = new URLSearchParams(window.location.search).get("section");
  return isSettingsSectionId(requested) ? requested : "general";
}

function successMessage(action: DesktopControlAction): string | null {
  if (action === "reset-settings") return "已恢复默认设置。已安装角色、外观包、日志和用户文件保持不变。";
  if (action === "open-log-directory") return "已打开日志目录。";
  if (action === "export-diagnostics") return "诊断文件已保存到本机，不会自动上传。";
  return null;
}

export function SettingsWindow({ client: providedClient, onClose }: Props) {
  const client = useMemo<SettingsWindowClientLike>(() => {
    if (providedClient) return providedClient;
    const explicitBrowserPreview = !isTauriRuntime() && new URLSearchParams(window.location.search).get("preview") === "1";
    return explicitBrowserPreview ? new BrowserPreviewSettingsClient() : new SettingsWindowClient();
  }, [providedClient]);
  const [snapshot, setSnapshot] = useState<DesktopControlSnapshot | null>(null);
  const [section, setSection] = useState<SettingsSectionId>(initialSectionFromLocation);
  const [pendingAction, setPendingAction] = useState<DesktopControlAction | null>(null);
  const [patchBusy, setPatchBusy] = useState(false);
  const [optimisticPatch, setOptimisticPatch] = useState<Partial<AppSettings>>({});
  const [feedback, setFeedback] = useState<Feedback | null>(null);
  const [resetOpen, setResetOpen] = useState(false);
  const focusSectionAfterNavigation = useRef(false);
  const desiredPatch = useRef<Partial<AppSettings>>({});
  const queuedPatch = useRef<Partial<AppSettings> | null>(null);
  const patchInFlight = useRef(false);
  const patchFlush = useRef<Promise<boolean> | null>(null);
  const mounted = useRef(true);

  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; };
  }, []);

  useEffect(() => {
    const unsubscribeSnapshot = client.subscribeSnapshot((next) => setSnapshot(next));
    const unsubscribeNavigation = client.subscribeNavigation((next) => {
      focusSectionAfterNavigation.current = true;
      setSection(next);
    });
    void client.start().catch(() => setFeedback({ tone: "danger", message: "暂时无法连接七酱桌宠，请关闭设置后重试。" }));
    return () => {
      unsubscribeSnapshot();
      unsubscribeNavigation();
      const pendingFlush = patchFlush.current;
      if (pendingFlush) void pendingFlush.finally(() => client.stop());
      else client.stop();
    };
  }, [client]);

  useEffect(() => {
    if (!snapshot || !focusSectionAfterNavigation.current) return;
    focusSectionAfterNavigation.current = false;
    document.getElementById("settings-section-title")?.focus();
  }, [section, snapshot]);

  const navigate = useCallback((next: SettingsSectionId, focusContent: boolean) => {
    focusSectionAfterNavigation.current = focusContent;
    setSection(next);
  }, []);

  const request = useCallback(async (action: DesktopControlAction, payload?: unknown) => {
    if (!snapshot || pendingAction || patchInFlight.current || queuedPatch.current) return;
    setPendingAction(action);
    setFeedback(null);
    try {
      const result = await client.request(action, payload);
      if (!result.ok) {
        setFeedback({ tone: "danger", message: result.error?.message ?? "操作未完成，请重试或查看日志。" });
        return;
      }
      const message = successMessage(action);
      if (message) setFeedback({ tone: "success", message });
      if (action === "reset-settings") setResetOpen(false);
    } catch {
      setFeedback({ tone: "danger", message: "操作未完成，请重试或查看日志。" });
    } finally {
      setPendingAction(null);
    }
  }, [client, pendingAction, snapshot]);

  const flushPatchQueue = useCallback((): Promise<boolean> => {
    if (patchFlush.current) return patchFlush.current;
    patchInFlight.current = true;
    if (mounted.current) setPatchBusy(true);
    const run = (async () => {
      let finalError: string | null = null;
      while (queuedPatch.current) {
        const value = queuedPatch.current;
        queuedPatch.current = null;
        try {
          const result = await client.request("patch-settings", { patch: value });
          if (mounted.current && result.snapshot) setSnapshot(result.snapshot);
          finalError = result.ok
            ? null
            : result.error?.message ?? "这项设置未能保存，已保留原来的设置。请重试或查看日志。";
        } catch {
          finalError = "这项设置未能保存，已保留原来的设置。请重试或查看日志。";
        }
      }

      patchInFlight.current = false;
      desiredPatch.current = {};
      if (mounted.current) {
        setOptimisticPatch({});
        setPatchBusy(false);
        if (finalError) setFeedback({ tone: "danger", message: finalError });
      }
      return finalError === null;
    })();
    patchFlush.current = run.finally(() => { patchFlush.current = null; });
    return patchFlush.current;
  }, [client]);

  useEffect(() => {
    if (!isTauriRuntime()) return;
    let disposed = false;
    let unlisten: (() => void) | undefined;
    const currentWindow = getCurrentWindow();
    const destroyWindow = () => currentWindow.destroy()
      .catch((error) => log("warn", "关闭设置窗口失败", error));
    void currentWindow.onCloseRequested((event) => {
      // Tauri automatically prevents native close while a JavaScript close
      // listener exists. Explicitly destroy after any required save finishes.
      event.preventDefault();
      if (!patchInFlight.current && !queuedPatch.current) {
        void destroyWindow();
        return;
      }
      void flushPatchQueue().then((saved) => {
        if (!saved || disposed) return;
        return destroyWindow();
      }).catch(() => undefined);
    }).then((dispose) => {
      if (disposed) dispose();
      else unlisten = dispose;
    }).catch(() => undefined);
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, [flushPatchQueue]);

  const patch = useCallback((value: Partial<AppSettings>) => {
    if (!snapshot || pendingAction) return;
    desiredPatch.current = { ...desiredPatch.current, ...value };
    queuedPatch.current = desiredPatch.current;
    setOptimisticPatch(desiredPatch.current);
    setFeedback(null);
    void flushPatchQueue();
  }, [flushPatchQueue, pendingAction, snapshot]);

  const visibleSnapshot = useMemo<DesktopControlSnapshot | null>(() => snapshot ? {
    ...snapshot,
    settings: { ...snapshot.settings, ...optimisticPatch },
  } : null, [optimisticPatch, snapshot]);

  const updateBusy = snapshot ? snapshot.updater.status === "installing" || snapshot.updater.status === "restarting" : false;
  const controlsDisabled = !snapshot || pendingAction !== null;
  const actionsDisabled = controlsDisabled || patchBusy;
  const close = useCallback(() => {
    if (patchInFlight.current || queuedPatch.current) return;
    onClose?.();
  }, [onClose]);

  return (
    <div className="settings-window" aria-busy={!snapshot || pendingAction !== null || patchBusy}>
      <WindowHeader
        title="七酱桌宠设置"
        description="更改会即时保存并立即生效。"
        onClose={onClose ? close : undefined}
        closeDisabled={updateBusy || patchBusy}
      />
      <div className="settings-window-layout">
        <SettingsNavigation current={section} onNavigate={navigate} />
        <main className="settings-window-content" aria-labelledby="settings-window-title">
          {!snapshot && !feedback && <p role="status">正在读取设置…</p>}
          {feedback && <InlineAlert tone={feedback.tone}>{feedback.message}</InlineAlert>}
          {visibleSnapshot && section === "general" && <GeneralSettingsPage snapshot={visibleSnapshot} disabled={controlsDisabled} actionDisabled={actionsDisabled} onPatch={patch} onAction={(action, payload) => void request(action, payload)} />}
          {visibleSnapshot && section === "appearance" && <AppearanceSettingsPage snapshot={visibleSnapshot} disabled={controlsDisabled} actionDisabled={actionsDisabled} onPatch={patch} onAction={(action, payload) => void request(action, payload)} />}
          {visibleSnapshot && section === "behavior" && <BehaviorSettingsPage snapshot={visibleSnapshot} disabled={controlsDisabled} actionDisabled={actionsDisabled} onPatch={patch} onAction={(action, payload) => void request(action, payload)} />}
          {visibleSnapshot && section === "update" && <UpdateSettingsPage snapshot={visibleSnapshot} disabled={controlsDisabled} actionDisabled={actionsDisabled} onPatch={patch} onAction={(action, payload) => void request(action, payload)} />}
          {visibleSnapshot && section === "about" && <AboutSettingsPage snapshot={visibleSnapshot} disabled={controlsDisabled} actionDisabled={actionsDisabled} onPatch={patch} onAction={(action, payload) => void request(action, payload)} feedback={feedback} onRequestReset={() => { if (!actionsDisabled) setResetOpen(true); }} />}
        </main>
      </div>
      <ConfirmDialog
        open={resetOpen}
        title="恢复默认设置？"
        confirmLabel="恢复默认设置"
        busy={pendingAction === "reset-settings"}
        onCancel={() => setResetOpen(false)}
        onConfirm={() => void request("reset-settings")}
      >
        <p>这会重置窗口位置、缩放、行为和更新偏好。</p>
        <p>不会删除已安装角色、`.qipet` 外观包、日志、应用或用户文件。</p>
      </ConfirmDialog>
    </div>
  );
}
