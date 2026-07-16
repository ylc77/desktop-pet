import { Channel, invoke } from "@tauri-apps/api/core";
import { relaunch } from "@tauri-apps/plugin-process";
import { isTauriRuntime } from "../window/windowController";
import type { AvailableUpdate, UpdaterClient, UpdaterRuntimeConfiguration } from "./updaterTypes";

interface NativeProgressEvent {
  event: "started" | "progress" | "finished";
  data?: { chunkLength?: number; contentLength?: number | null };
}

const browserConfiguration: UpdaterRuntimeConfiguration = {
  configured: false,
  status: "unsupported",
  applicationName: "七酱桌宠",
  currentVersion: "0.1.0",
  channel: "beta",
  endpointDomain: null,
  publicKeyFingerprint: null,
  installMode: "passive",
};

export function createNativeUpdaterClient(): UpdaterClient {
  return {
    getConfiguration: () => isTauriRuntime()
      ? invoke<UpdaterRuntimeConfiguration>("get_updater_configuration")
      : Promise.resolve(browserConfiguration),
    check: () => isTauriRuntime()
      ? invoke<AvailableUpdate | null>("check_for_update")
      : Promise.resolve(null),
    async download(onProgress) {
      if (!isTauriRuntime()) throw { category: "unsupported", message: "当前环境不支持应用更新" };
      const channel = new Channel<NativeProgressEvent>();
      channel.onmessage = (message) => {
        if (message.event === "started") onProgress({ chunkLength: 0, contentLength: message.data?.contentLength ?? null });
        if (message.event === "progress") onProgress({ chunkLength: message.data?.chunkLength ?? 0, contentLength: message.data?.contentLength ?? null });
      };
      await invoke("download_update", { onEvent: channel });
    },
    async install() {
      if (!isTauriRuntime()) throw { category: "unsupported", message: "当前环境不支持应用更新" };
      await invoke("install_update");
    },
    async relaunch() {
      if (!isTauriRuntime()) return;
      await relaunch();
    },
    async cancelPending() {
      if (!isTauriRuntime()) return;
      await invoke("cancel_pending_update");
    },
  };
}
