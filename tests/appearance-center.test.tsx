import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { AppearanceCenter, type AppearanceCenterApi } from "../src/components/AppearanceCenter/AppearanceCenter";
import type { CharacterCatalogEntry, CharacterSelectionChanged } from "../src/core/character/CharacterCatalog";

const bundled: CharacterCatalogEntry = {
  id: "official",
  name: "官方占位",
  version: "1.0.0",
  author: "七酱桌宠",
  license: "Project only",
  source: "bundled",
  valid: true,
  errors: [],
  previewUrl: "/characters/official/preview.png",
};

const local: CharacterCatalogEntry = {
  id: "personal",
  name: "我的角色",
  version: "2.0.0",
  author: "用户",
  license: "Private use",
  source: "local",
  valid: true,
  errors: [],
};

const broken: CharacterCatalogEntry = {
  ...local,
  id: "broken",
  name: "损坏角色",
  valid: false,
  errors: ["idle 动画没有可用帧"],
};

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

function makeApi(imported = true, selectedId = "official") {
  let changed: ((change: CharacterSelectionChanged) => void) | undefined;
  const api: AppearanceCenterApi = {
    list: vi.fn(async () => [bundled, local, broken]),
    importPackage: vi.fn(async () => imported ? local : null),
    remove: vi.fn(async () => undefined),
    requestSelection: vi.fn(async () => undefined),
    listenSelectionChanged: vi.fn(async (handler) => {
      changed = handler;
      return () => undefined;
    }),
    currentCharacterId: vi.fn(async () => selectedId),
  };
  return { api, change: (payload: CharacterSelectionChanged) => changed?.(payload) };
}

describe("AppearanceCenter", () => {
  it("shows lazy previews, source/status metadata, and blocks broken selections", async () => {
    const { api } = makeApi();
    render(<AppearanceCenter api={api} />);

    expect(await screen.findByRole("heading", { name: "官方占位" })).toBeInTheDocument();
    expect(screen.getByText("官方")).toBeInTheDocument();
    expect(screen.getAllByText("本机私用")).toHaveLength(2);
    expect(screen.getByText("当前使用")).toBeInTheDocument();
    expect(screen.getByText("资源损坏")).toBeInTheDocument();
    expect(screen.getByText("idle 动画没有可用帧")).toBeInTheDocument();
    expect(screen.getByAltText("官方占位 预览")).toHaveAttribute("loading", "lazy");
    const brokenCard = screen.getByRole("heading", { name: "损坏角色" }).closest("article")!;
    expect(brokenCard.querySelector<HTMLButtonElement>("button.primary")).toBeDisabled();
  });

  it("requests a source-aware switch and only marks it current after success", async () => {
    const { api, change } = makeApi();
    render(<AppearanceCenter api={api} />);
    const localHeading = await screen.findByRole("heading", { name: "我的角色" });
    const localCard = localHeading.closest("article")!;
    fireEvent.click(localCard.querySelector<HTMLButtonElement>("button.primary")!);

    expect(api.requestSelection).toHaveBeenCalledWith({ id: "personal", source: "local", requestId: expect.any(String), expiresAtMs: expect.any(Number) });
    expect(localCard).not.toHaveClass("current");
    const request = vi.mocked(api.requestSelection).mock.calls[0][0];
    change({ id: "personal", source: "local", requestId: request.requestId, ok: true });
    await waitFor(() => expect(localCard).toHaveClass("current"));
    expect(localCard.querySelector<HTMLButtonElement>("button.danger")).toBeDisabled();
    expect(screen.getByText("外观已更换")).toBeInTheDocument();
  });

  it("keeps trusted bundled IDs native and distinguishes import cancellation", async () => {
    const { api } = makeApi(false);
    render(<AppearanceCenter api={api} />);
    await screen.findByRole("heading", { name: "官方占位" });
    fireEvent.click(screen.getByRole("button", { name: "导入角色包" }));
    await waitFor(() => expect(api.importPackage).toHaveBeenCalledWith());
    expect(await screen.findByText("已取消导入")).toBeInTheDocument();
  });

  it("transactionally reloads an imported upgrade when it is the active local role", async () => {
    const { api } = makeApi(true, "personal");
    render(<AppearanceCenter api={api} />);
    await screen.findByRole("heading", { name: "我的角色" });
    fireEvent.click(screen.getByRole("button", { name: "导入角色包" }));
    await waitFor(() => expect(api.requestSelection).toHaveBeenCalledWith({ id: "personal", source: "local", requestId: expect.any(String), expiresAtMs: expect.any(Number) }));
    expect(screen.getByText(/角色包已更新，正在验证并重新加载/)).toBeInTheDocument();
  });

  it("deletes a non-active local package only after explicit confirmation", async () => {
    const { api } = makeApi();
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(true);
    render(<AppearanceCenter api={api} />);
    const localCard = (await screen.findByRole("heading", { name: "我的角色" })).closest("article")!;

    fireEvent.click(localCard.querySelector<HTMLButtonElement>("button.danger")!);

    await waitFor(() => expect(api.remove).toHaveBeenCalledWith("personal"));
    expect(confirm).toHaveBeenCalledWith("确定从本机删除“我的角色”吗？");
    expect(await screen.findByText("本地角色已删除")).toBeInTheDocument();
  });

  it("clears its busy state when the main window reports a cancelled request", async () => {
    const { api, change } = makeApi();
    render(<AppearanceCenter api={api} />);
    const localCard = (await screen.findByRole("heading", { name: "我的角色" })).closest("article")!;
    const selectButton = localCard.querySelector<HTMLButtonElement>("button.primary")!;
    fireEvent.click(selectButton);
    await waitFor(() => expect(api.requestSelection).toHaveBeenCalled());
    const request = vi.mocked(api.requestSelection).mock.calls[0][0];

    change({ id: "personal", source: "local", requestId: request.requestId, ok: false, error: "切换已取消" });

    await waitFor(() => expect(selectButton).not.toBeDisabled());
    expect(screen.getByText(/切换已取消/)).toBeInTheDocument();
  });

  it("recovers from a missing selection result after a bounded wait", async () => {
    const { api, change } = makeApi();
    render(<AppearanceCenter api={api} selectionTimeoutMs={25} />);
    const localCard = (await screen.findByRole("heading", { name: "我的角色" })).closest("article")!;
    const selectButton = localCard.querySelector<HTMLButtonElement>("button.primary")!;
    fireEvent.click(selectButton);

    expect(await screen.findByText(/外观切换等待超时/)).toBeInTheDocument();
    expect(selectButton).not.toBeDisabled();
    const request = vi.mocked(api.requestSelection).mock.calls[0][0];
    change({ id: "personal", source: "local", requestId: request.requestId, ok: true });
    expect(localCard).not.toHaveClass("current");
    expect(screen.getByText(/外观切换等待超时/)).toBeInTheDocument();
  });

  it("retries a preview after an upgraded package changes its URL", async () => {
    const { api } = makeApi();
    vi.mocked(api.list)
      .mockResolvedValueOnce([bundled])
      .mockResolvedValueOnce([{ ...bundled, version: "1.1.0", previewUrl: "/characters/official/preview.png?v=1.1.0" }]);
    render(<AppearanceCenter api={api} />);
    const oldPreview = await screen.findByAltText("官方占位 预览");
    fireEvent.error(oldPreview);
    expect(screen.getByLabelText("没有预览图")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "刷新" }));

    await waitFor(() => expect(screen.getByAltText("官方占位 预览")).toHaveAttribute("src", "/characters/official/preview.png?v=1.1.0"));
  });
});
