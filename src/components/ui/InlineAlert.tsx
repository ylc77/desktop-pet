import type { ReactNode } from "react";

interface Props {
  tone: "info" | "success" | "warning" | "danger";
  children: ReactNode;
}

export function InlineAlert({ tone, children }: Props) {
  const urgent = tone === "danger";
  return <div className={`inline-alert ${tone}`} role={urgent ? "alert" : "status"}>{children}</div>;
}
