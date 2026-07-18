import { useCallback, useEffect, useMemo, useRef, useState } from "react";
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
  const [feedback, setFeedback] = useState<Feedback | null>(null);
  const [resetOpen, setResetOpen] = useState(false);
  const focusSectionAfterNavigation = useRef(false);

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
      client.stop();
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
    if (!snapshot || pendingAction) return;
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

  const patch = useCallback((value: Partial<AppSettings>) => {
    void request("patch-settings", { patch: value });
  }, [request]);

  const updateBusy = snapshot ? snapshot.updater.status === "installing" || snapshot.updater.status === "restarting" : false;
  const controlsDisabled = !snapshot || pendingAction !== null;

  return (
    <div className="settings-window" aria-busy={!snapshot || pendingAction !== null}>
      <WindowHeader
        title="七酱桌宠设置"
        description="更改会在确认保存后立即生效。"
        onClose={onClose}
        closeDisabled={updateBusy}
      />
      <div className="settings-window-layout">
        <SettingsNavigation current={section} onNavigate={navigate} />
        <main className="settings-window-content" aria-labelledby="settings-window-title">
          {!snapshot && !feedback && <p role="status">正在读取设置…</p>}
          {feedback && <InlineAlert tone={feedback.tone}>{feedback.message}</InlineAlert>}
          {snapshot && section === "general" && <GeneralSettingsPage snapshot={snapshot} disabled={controlsDisabled} onPatch={patch} onAction={(action, payload) => void request(action, payload)} />}
          {snapshot && section === "appearance" && <AppearanceSettingsPage snapshot={snapshot} disabled={controlsDisabled} onPatch={patch} onAction={(action, payload) => void request(action, payload)} />}
          {snapshot && section === "behavior" && <BehaviorSettingsPage snapshot={snapshot} disabled={controlsDisabled} onPatch={patch} onAction={(action, payload) => void request(action, payload)} />}
          {snapshot && section === "update" && <UpdateSettingsPage snapshot={snapshot} disabled={controlsDisabled} onPatch={patch} onAction={(action, payload) => void request(action, payload)} />}
          {snapshot && section === "about" && <AboutSettingsPage snapshot={snapshot} disabled={controlsDisabled} onPatch={patch} onAction={(action, payload) => void request(action, payload)} feedback={feedback} onRequestReset={() => setResetOpen(true)} />}
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
