export type RootSurfaceId = "main" | "appearance" | "settings" | "unknown";

const supportedSurfaces = new Set<RootSurfaceId>(["main", "appearance", "settings"]);

export function resolveRootSurfaceId(windowLabel: string | null, search: string): RootSurfaceId {
  const requested = windowLabel ?? new URLSearchParams(search).get("surface") ?? "main";
  return supportedSurfaces.has(requested as RootSurfaceId) ? requested as RootSurfaceId : "unknown";
}
