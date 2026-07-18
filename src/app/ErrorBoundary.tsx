import { Component, type ErrorInfo, type ReactNode } from "react";
import { log } from "../core/diagnostics/logger";

export class ErrorBoundary extends Component<{ children: ReactNode }, { error: Error | null }> {
  state: { error: Error | null } = { error: null };
  static getDerivedStateFromError(error: Error) { return { error }; }
  componentDidCatch(error: Error, info: ErrorInfo) { log("error", `界面错误: ${info.componentStack ?? "unknown"}`, error); }
  render() {
    if (this.state.error) return (
      <main className="fatal-error" role="alert" aria-labelledby="fatal-error-title">
        <strong id="fatal-error-title">七酱桌宠暂时无法显示这个页面</strong>
        <p>界面发生了意外错误。你可以重新加载；详细信息已写入本机日志。</p>
        <button type="button" onClick={() => location.reload()}>重新加载</button>
      </main>
    );
    return this.props.children;
  }
}
