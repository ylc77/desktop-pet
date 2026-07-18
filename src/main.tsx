import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { getCurrentWindow } from "@tauri-apps/api/window";
import App from "./app/App";
import { ErrorBoundary } from "./app/ErrorBoundary";
import { resolveRootSurfaceId } from "./app/rootSurface";
import { AppearanceCenter } from "./components/AppearanceCenter/AppearanceCenter";
import { SettingsWindow } from "./components/SettingsWindow";
import "./styles.css";

function UnknownSurface() {
  return <main className="fatal-error" role="alert"><strong>无法打开这个七酱桌宠窗口</strong><p>窗口类型无效，请关闭后从桌宠或系统托盘重新打开。</p></main>;
}

const label = "__TAURI_INTERNALS__" in window ? getCurrentWindow().label : null;
const surface = resolveRootSurfaceId(label, window.location.search);
const RootSurface = surface === "main" ? App
  : surface === "appearance" ? AppearanceCenter
    : surface === "settings" ? SettingsWindow
      : UnknownSurface;

createRoot(document.getElementById("root")!).render(<StrictMode><ErrorBoundary><RootSurface /></ErrorBoundary></StrictMode>);
