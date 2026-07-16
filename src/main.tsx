import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { getCurrentWindow } from "@tauri-apps/api/window";
import App from "./app/App";
import { ErrorBoundary } from "./app/ErrorBoundary";
import { AppearanceCenter } from "./components/AppearanceCenter/AppearanceCenter";
import "./styles.css";

const RootSurface = "__TAURI_INTERNALS__" in window && getCurrentWindow().label === "appearance" ? AppearanceCenter : App;

createRoot(document.getElementById("root")!).render(<StrictMode><ErrorBoundary><RootSurface /></ErrorBoundary></StrictMode>);
