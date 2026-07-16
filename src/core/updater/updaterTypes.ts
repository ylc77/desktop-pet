export type UpdaterStatus =
  | "disabled"
  | "idle"
  | "checking"
  | "upToDate"
  | "available"
  | "downloading"
  | "readyToInstall"
  | "installing"
  | "restarting"
  | "postponed"
  | "skipped"
  | "cancelled"
  | "error";

export type UpdaterFailureCategory =
  | "notConfigured"
  | "offline"
  | "timeout"
  | "endpointNotFound"
  | "invalidMetadata"
  | "invalidSignature"
  | "downloadInterrupted"
  | "permissionDenied"
  | "installFailed"
  | "restartFailed"
  | "unsupported"
  | "busy"
  | "unknown";

export interface UpdaterRuntimeConfiguration {
  configured: boolean;
  status: "configured" | "notConfigured" | "unsupported";
  applicationName: string;
  currentVersion: string;
  channel: "beta" | "stable";
  endpointDomain: string | null;
  publicKeyFingerprint: string | null;
  installMode: "passive";
}

export interface AvailableUpdate {
  currentVersion: string;
  version: string;
  notes: string | null;
  publishedAt: string | null;
  contentLength: number | null;
}

export interface UpdateDownloadProgress {
  downloadedBytes: number;
  totalBytes: number | null;
  percent: number | null;
}

export interface UpdaterErrorInfo {
  category: UpdaterFailureCategory;
  message: string;
}

export interface UpdaterTransition {
  from: UpdaterStatus;
  to: UpdaterStatus;
  reason: string;
  at: string;
}

export interface UpdaterSnapshot {
  status: UpdaterStatus;
  reason: string;
  transitionedAt: string;
  configuration: UpdaterRuntimeConfiguration | null;
  update: AvailableUpdate | null;
  progress: UpdateDownloadProgress | null;
  error: UpdaterErrorInfo | null;
  transitions: readonly UpdaterTransition[];
}

export interface UpdaterClient {
  getConfiguration(): Promise<UpdaterRuntimeConfiguration>;
  check(): Promise<AvailableUpdate | null>;
  download(onProgress: (progress: { chunkLength: number; contentLength: number | null }) => void): Promise<void>;
  install(): Promise<void>;
  relaunch(): Promise<void>;
  cancelPending(): Promise<void>;
}

export interface CheckOptions {
  manual: boolean;
  skippedVersion?: string | null;
}

export interface InstallPreparation {
  beforeInstall(): Promise<void>;
}
