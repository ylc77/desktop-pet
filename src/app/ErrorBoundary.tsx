import { Component, type ErrorInfo, type ReactNode } from "react";
import { log } from "../core/diagnostics/logger";

export class ErrorBoundary extends Component<{ children: ReactNode }, { error: Error | null }> {
  state: { error: Error | null } = { error: null };
  static getDerivedStateFromError(error: Error) { return { error }; }
  componentDidCatch(error: Error, info: ErrorInfo) { log("error", `界面错误: ${info.componentStack ?? "unknown"}`, error); }
  render() {
    if (this.state.error) return <div className="fatal-error"><strong>七酱桌宠界面发生错误</strong><p>{this.state.error.message}</p><button onClick={() => location.reload()}>重新加载</button></div>;
    return this.props.children;
  }
}
