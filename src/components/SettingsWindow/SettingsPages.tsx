import type { AppSettings } from "../../core/settings/settingsSchema";
import type { DesktopCharacterSummary, DesktopControlAction, DesktopControlSnapshot } from "../../core/desktopControl";
import type { UpdaterFailureCategory, UpdaterSnapshot } from "../../core/updater/updaterTypes";
import { AboutSupportContent } from "../AboutPanel/AboutPanel";
import { InlineAlert, SettingsRow, Toggle } from "../ui";

interface CommonPageProps {
  snapshot: DesktopControlSnapshot;
  disabled: boolean;
  actionDisabled: boolean;
  onPatch: (patch: Partial<AppSettings>) => void;
  onAction: (action: DesktopControlAction, payload?: unknown) => void;
}

function SectionTitle({ children, description }: { children: string; description: string }) {
  return (
    <header className="settings-section-header">
      <h2 id="settings-section-title" tabIndex={-1}>{children}</h2>
      <p>{description}</p>
    </header>
  );
}

export function GeneralSettingsPage({ snapshot, disabled, onPatch }: CommonPageProps) {
  const { settings } = snapshot;
  return (
    <section aria-labelledby="settings-section-title">
      <SectionTitle description="控制七酱桌宠随 Windows 启动和停留在其他窗口上方的方式。">常规</SectionTitle>
      <div className="settings-section-card">
        <SettingsRow label="开机启动" description="登录 Windows 后自动启动七酱桌宠。">
          {({ labelId, descriptionId }) => <Toggle checked={settings.autostart} disabled={disabled} labelledBy={labelId} describedBy={descriptionId} onChange={(checked) => onPatch({ autostart: checked })} />}
        </SettingsRow>
        <SettingsRow label="始终置顶" description="让桌宠保持在普通窗口上方。">
          {({ labelId, descriptionId }) => <Toggle checked={settings.alwaysOnTop} disabled={disabled} labelledBy={labelId} describedBy={descriptionId} onChange={(checked) => onPatch({ alwaysOnTop: checked })} />}
        </SettingsRow>
      </div>
    </section>
  );
}

export function AppearanceSettingsPage({ snapshot, disabled, actionDisabled, onPatch, onAction }: CommonPageProps) {
  const { settings, character } = snapshot;
  return (
    <section aria-labelledby="settings-section-title">
      <SectionTitle description="调整当前角色、大小、透明度和朝向。">外观</SectionTitle>
      <div className="current-character-summary">
        <div>
          <strong>{character?.name ?? "正在读取当前角色"}</strong>
          {character && <p>{character.author} · {character.version}</p>}
        </div>
        <button type="button" className="primary" disabled={actionDisabled} onClick={() => onAction("open-appearance")}>打开外观中心</button>
      </div>
      <div className="settings-section-card">
        <SettingsRow label={`大小 ${Math.round(settings.scale * 100)}%`} description="只改变桌宠显示大小，不修改角色素材。">
          {({ labelId, descriptionId }) => <input type="range" min="0.1" max="4" step="0.05" value={settings.scale} disabled={disabled} aria-labelledby={labelId} aria-describedby={descriptionId} onChange={(event) => onPatch({ scale: event.currentTarget.valueAsNumber })} />}
        </SettingsRow>
        <SettingsRow label={`透明度 ${Math.round(settings.opacity * 100)}%`} description="最低保留 20% 可见度。">
          {({ labelId, descriptionId }) => <input type="range" min="0.2" max="1" step="0.05" value={settings.opacity} disabled={disabled} aria-labelledby={labelId} aria-describedby={descriptionId} onChange={(event) => onPatch({ opacity: event.currentTarget.valueAsNumber })} />}
        </SettingsRow>
        <SettingsRow label="默认朝向" description="角色空闲时优先面向的方向。">
          {({ labelId, descriptionId }) => (
            <select value={settings.facing} disabled={disabled} aria-labelledby={labelId} aria-describedby={descriptionId} onChange={(event) => onPatch({ facing: event.currentTarget.value as "left" | "right" })}>
              <option value="left">向左</option>
              <option value="right">向右</option>
            </select>
          )}
        </SettingsRow>
      </div>
    </section>
  );
}

export function BehaviorSettingsPage({ snapshot, disabled, onPatch }: CommonPageProps) {
  const { settings } = snapshot;
  return (
    <section aria-labelledby="settings-section-title">
      <SectionTitle description="调整桌宠互动、动画和全屏应用期间的行为。">行为</SectionTitle>
      <div className="settings-section-card">
        <SettingsRow label="启用互动" description="允许单击、双击、悬停和拖动触发角色动作。">
          {({ labelId, descriptionId }) => <Toggle checked={settings.interactionsEnabled} disabled={disabled} labelledBy={labelId} describedBy={descriptionId} onChange={(checked) => onPatch({ interactionsEnabled: checked })} />}
        </SettingsRow>
        <SettingsRow label="暂停动画" description="保留桌宠显示，但停止角色动画。">
          {({ labelId, descriptionId }) => <Toggle checked={settings.animationsPaused} disabled={disabled} labelledBy={labelId} describedBy={descriptionId} onChange={(checked) => onPatch({ animationsPaused: checked })} />}
        </SettingsRow>
        <SettingsRow label={`互动音量 ${Math.round(settings.volume * 100)}%`} description="角色包不包含声音时此设置不会产生效果。">
          {({ labelId, descriptionId }) => <input type="range" min="0" max="1" step="0.05" value={settings.volume} disabled={disabled} aria-labelledby={labelId} aria-describedby={descriptionId} onChange={(event) => onPatch({ volume: event.currentTarget.valueAsNumber })} />}
        </SettingsRow>
        <SettingsRow label="全屏时自动隐藏" description="检测到全屏应用时暂时隐藏桌宠。">
          {({ labelId, descriptionId }) => <Toggle checked={settings.hideInFullscreen} disabled={disabled} labelledBy={labelId} describedBy={descriptionId} onChange={(checked) => onPatch({ hideInFullscreen: checked })} />}
        </SettingsRow>
      </div>
    </section>
  );
}

const updaterFailureText: Record<UpdaterFailureCategory, string> = {
  notConfigured: "更新服务尚未配置。",
  offline: "暂时无法连接更新服务，请检查网络后重试。",
  timeout: "更新服务响应超时，请稍后重试。",
  endpointNotFound: "暂时找不到更新信息。",
  invalidMetadata: "更新信息格式无效，已停止更新。",
  invalidSignature: "更新文件未通过安全验证，因此没有安装。",
  downloadInterrupted: "更新下载已中断，可以安全重试。",
  permissionDenied: "Windows 拒绝了更新操作，请检查权限。",
  installFailed: "更新安装失败，七酱桌宠不会自动重启。",
  restartFailed: "更新流程已完成，但七酱桌宠未能自动重启。",
  unsupported: "当前环境不支持应用内更新。",
  busy: "已有更新任务正在进行。",
  unknown: "更新未完成，请重试或查看日志。",
};

function UpdateStatus({ updater, disabled, onAction }: { updater: UpdaterSnapshot; disabled: boolean; onAction: CommonPageProps["onAction"] }) {
  const configured = updater.configuration?.configured === true;
  const busy = ["checking", "downloading", "installing", "restarting"].includes(updater.status);
  const update = updater.update;
  return (
    <div className="update-settings-card">
      {!configured && <InlineAlert tone="info">更新服务尚未配置。七酱桌宠仍可正常离线使用，当前不会连接网络检查更新。</InlineAlert>}
      {configured && updater.status === "idle" && <p>尚未检查更新。</p>}
      {updater.status === "checking" && <p role="status">正在检查更新…</p>}
      {updater.status === "upToDate" && <InlineAlert tone="success">当前已经是最新版。</InlineAlert>}
      {update && <div className="update-version-summary"><strong>{update.currentVersion} → {update.version}</strong>{update.notes && <p>{update.notes}</p>}</div>}
      {updater.status === "downloading" && updater.progress && (
        <div>
          <p>正在下载并验证更新文件…</p>
          {updater.progress.percent === null
            ? <progress aria-label="正在下载更新文件" />
            : <progress aria-label="正在下载更新文件" max="100" value={updater.progress.percent} />}
          <p>{updater.progress.percent === null ? "总大小未知" : `${updater.progress.percent}%`}</p>
        </div>
      )}
      {updater.status === "readyToInstall" && <InlineAlert tone="success">下载和安全验证已完成，可以安装并重启。</InlineAlert>}
      {updater.status === "installing" && <p role="status">正在安装更新，请不要关闭应用…</p>}
      {updater.status === "restarting" && <p role="status">正在重新启动七酱桌宠…</p>}
      {updater.status === "postponed" && <p role="status">已选择稍后提醒。</p>}
      {updater.status === "skipped" && <p role="status">已跳过此版本，以后仍可手动检查。</p>}
      {updater.status === "cancelled" && <p role="status">本次更新已取消。</p>}
      {updater.status === "error" && updater.error && <InlineAlert tone="danger">{updaterFailureText[updater.error.category]}</InlineAlert>}
      <div className="panel-actions">
        <button type="button" disabled={disabled || busy || !configured || updater.status === "readyToInstall"} onClick={() => onAction("check-updates")}>检查更新</button>
        {updater.status === "available" && update && <>
          <button type="button" className="primary" disabled={disabled} onClick={() => onAction("update-now")}>立即更新</button>
          <button type="button" disabled={disabled} onClick={() => onAction("update-later")}>稍后提醒</button>
          <button type="button" disabled={disabled} onClick={() => onAction("update-skip", { version: update.version })}>跳过此版本</button>
        </>}
        {updater.status === "readyToInstall" && <button type="button" className="primary" disabled={disabled} onClick={() => onAction("update-now")}>安装并重启</button>}
        {updater.status === "error" && <button type="button" disabled={disabled || busy} onClick={() => onAction("update-retry")}>重试</button>}
      </div>
    </div>
  );
}

export function UpdateSettingsPage({ snapshot, disabled, actionDisabled, onPatch, onAction }: CommonPageProps) {
  const version = snapshot.updater.configuration?.currentVersion ?? "读取中…";
  const channel = snapshot.updater.configuration?.channel ?? "stable";
  return (
    <section aria-labelledby="settings-section-title">
      <SectionTitle description="更新只会在你确认后下载和安装。">更新</SectionTitle>
      <div className="settings-section-card">
        <SettingsRow label="自动检查更新" description="启动后按安全策略检查，不会自动下载或安装。">
          {({ labelId, descriptionId }) => <Toggle checked={snapshot.settings.automaticUpdateChecks} disabled={disabled} labelledBy={labelId} describedBy={descriptionId} onChange={(checked) => onPatch({ automaticUpdateChecks: checked })} />}
        </SettingsRow>
        <dl className="update-metadata">
          <div><dt>当前版本</dt><dd>{version}</dd></div>
          <div><dt>更新渠道</dt><dd>{channel}</dd></div>
        </dl>
      </div>
      <UpdateStatus updater={snapshot.updater} disabled={actionDisabled} onAction={onAction} />
    </section>
  );
}

interface AboutPageProps extends CommonPageProps {
  feedback: { tone: "info" | "success" | "warning" | "danger"; message: string } | null;
  onRequestReset: () => void;
}

export function AboutSettingsPage({ snapshot, actionDisabled, feedback, onAction, onRequestReset }: AboutPageProps) {
  return (
    <section aria-labelledby="settings-section-title">
      <SectionTitle description="查看版本、隐私说明以及本机诊断工具。">关于与支持</SectionTitle>
      <AboutSupportContent
        currentVersion={snapshot.updater.configuration?.currentVersion ?? "读取中…"}
        channel={snapshot.updater.configuration?.channel ?? "stable"}
        lastCheckAt={snapshot.settings.updateLastCheckAt}
        character={snapshot.character as DesktopCharacterSummary | null}
        busy={actionDisabled}
        feedback={feedback}
        onCheckUpdates={() => onAction("check-updates")}
        onOpenLogDirectory={() => onAction("open-log-directory")}
        onExportDiagnostics={() => onAction("export-diagnostics")}
        onRequestReset={onRequestReset}
      />
    </section>
  );
}
