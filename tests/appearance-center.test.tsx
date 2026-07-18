import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
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

const placeholder: CharacterCatalogEntry = {
  ...bundled,
  id: "_placeholder",
  name: "中性占位角色",
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

function makeApi(imported = true, selectedId = "official", catalog: CharacterCatalogEntry[] = [bundled, local, broken]) {
  let changed: ((change: CharacterSelectionChanged) => void) | undefined;
  let currentId = selectedId;
  let currentCatalog = [...catalog];
  const api: AppearanceCenterApi = {
    list: vi.fn(async () => currentCatalog),
    importPackage: vi.fn(async () => imported ? local : null),
    remove: vi.fn(async (id: string) => {
      currentCatalog = currentCatalog.filter((entry) => entry.source !== "local" || entry.id !== id);
    }),
    requestSelection: vi.fn(async () => undefined),
    listenSelectionChanged: vi.fn(async (handler) => {
      changed = handler;
      return () => undefined;
    }),
    currentCharacterId: vi.fn(async () => currentId),
  };
  return {
    api,
    change: (payload: CharacterSelectionChanged) => {
      if (payload.ok) currentId = payload.id;
      changed?.(payload);
    },
  };
}

describe("AppearanceCenter", () => {
  it("protects an accepted delete transaction from window-close interruption", () => {
    const source = readFileSync(resolve(process.cwd(), "src/components/AppearanceCenter/AppearanceCenter.tsx"), "utf8");
    expect(source).toContain("onCloseRequested");
    expect(source).toContain("removalTransactionActive.current");
    expect(source).toContain("event.preventDefault()");
    expect(source).toContain("finishRemovalTransaction()");
  });

  it("shows lazy previews, source/status metadata, and blocks broken selections", async () => {
    const { api } = makeApi();
    render(<AppearanceCenter api={api} />);

    expect(await screen.findByRole("heading", { name: "官方占位" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "当前角色" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "官方内置角色" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "本机私用角色" })).toBeInTheDocument();
    expect(screen.getAllByText("官方")).toHaveLength(2);
    expect(screen.getAllByText("本机私用")).toHaveLength(2);
    expect(screen.getAllByText("当前使用")).toHaveLength(2);
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
    expect(localCard.querySelector<HTMLButtonElement>("button.danger")).toBeEnabled();
    expect(screen.getByText("删除前会先切换到安全的内置外观")).toBeInTheDocument();
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

  it("deletes a non-active local package only after accessible confirmation", async () => {
    const { api } = makeApi();
    const confirm = vi.spyOn(window, "confirm");
    render(<AppearanceCenter api={api} />);
    const localCard = (await screen.findByRole("heading", { name: "我的角色" })).closest("article")!;

    fireEvent.click(localCard.querySelector<HTMLButtonElement>("button.danger")!);
    const dialog = screen.getByRole("dialog", { name: "删除角色" });
    expect(dialog).toHaveTextContent("确定从本机删除“我的角色”吗");
    expect(screen.getByRole("button", { name: "取消" })).toHaveFocus();
    fireEvent.click(screen.getByRole("button", { name: "删除角色" }));

    await waitFor(() => expect(api.remove).toHaveBeenCalledWith("personal"));
    expect(confirm).not.toHaveBeenCalled();
    expect(await screen.findByText("本地角色已删除")).toBeInTheDocument();
    await waitFor(() => expect(screen.getByRole("heading", { name: "本机私用角色" })).toHaveFocus());
  });

  it("switches through the native handshake before deleting the active local package", async () => {
    const { api, change } = makeApi(true, "personal");
    render(<AppearanceCenter api={api} />);
    const localCard = (await screen.findByRole("heading", { name: "我的角色" })).closest("article")!;
    const deleteButton = localCard.querySelector<HTMLButtonElement>("button.danger")!;
    deleteButton.focus();
    fireEvent.click(deleteButton);

    expect(screen.getByRole("dialog", { name: "删除角色" })).toHaveTextContent("删除前会先切换到安全的内置外观");
    fireEvent.click(screen.getByRole("button", { name: "删除角色" }));
    expect(screen.getByRole("heading", { name: "本机私用角色" })).toHaveFocus();
    await waitFor(() => expect(api.requestSelection).toHaveBeenCalledWith({
      id: "official",
      source: "bundled",
      requestId: expect.any(String),
      expiresAtMs: expect.any(Number),
    }));
    expect(api.remove).not.toHaveBeenCalled();

    const request = vi.mocked(api.requestSelection).mock.calls[0][0];
    change({ id: "official", source: "bundled", requestId: request.requestId, ok: true });

    await waitFor(() => expect(api.remove).toHaveBeenCalledWith("personal"));
    expect(await screen.findByText("本地角色已删除")).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "我的角色" })).not.toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "官方占位" }).closest("article")).toHaveClass("current");
    await waitFor(() => expect(screen.getByRole("heading", { name: "本机私用角色" })).toHaveFocus());
  });

  it("prefers the bundled placeholder when deleting the active local package", async () => {
    const { api } = makeApi(true, "personal", [bundled, placeholder, local]);
    render(<AppearanceCenter api={api} />);
    const localCard = (await screen.findByRole("heading", { name: "我的角色" })).closest("article")!;
    fireEvent.click(localCard.querySelector<HTMLButtonElement>("button.danger")!);
    fireEvent.click(screen.getByRole("button", { name: "删除角色" }));

    await waitFor(() => expect(api.requestSelection).toHaveBeenCalledWith({
      id: "_placeholder",
      source: "bundled",
      requestId: expect.any(String),
      expiresAtMs: expect.any(Number),
    }));
  });

  it("keeps the active local package and restores focus when fallback selection fails", async () => {
    const { api, change } = makeApi(true, "personal");
    render(<AppearanceCenter api={api} />);
    const localCard = (await screen.findByRole("heading", { name: "我的角色" })).closest("article")!;
    const deleteButton = localCard.querySelector<HTMLButtonElement>("button.danger")!;
    deleteButton.focus();
    fireEvent.click(deleteButton);
    fireEvent.click(screen.getByRole("button", { name: "删除角色" }));
    await waitFor(() => expect(api.requestSelection).toHaveBeenCalled());
    const request = vi.mocked(api.requestSelection).mock.calls[0][0];

    change({ id: "official", source: "bundled", requestId: request.requestId, ok: false, error: "资源验证失败" });

    expect(await screen.findByRole("alert")).toHaveTextContent("当前角色未删除：资源验证失败");
    expect(api.remove).not.toHaveBeenCalled();
    expect(localCard).toHaveClass("current");
    await waitFor(() => expect(deleteButton).toHaveFocus());
  });

  it("keeps the local package and restores delete focus when removal fails", async () => {
    const { api } = makeApi();
    vi.mocked(api.remove).mockRejectedValueOnce(new Error("文件被占用"));
    render(<AppearanceCenter api={api} />);
    const localCard = (await screen.findByRole("heading", { name: "我的角色" })).closest("article")!;
    const deleteButton = localCard.querySelector<HTMLButtonElement>("button.danger")!;
    deleteButton.focus();
    fireEvent.click(deleteButton);
    fireEvent.click(screen.getByRole("button", { name: "删除角色" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("删除失败：文件被占用");
    expect(screen.getByRole("heading", { name: "我的角色" })).toBeInTheDocument();
    await waitFor(() => expect(deleteButton).toHaveFocus());
  });

  it("returns focus to delete when the confirmation is cancelled with Escape", async () => {
    const { api } = makeApi();
    render(<AppearanceCenter api={api} />);
    const localCard = (await screen.findByRole("heading", { name: "我的角色" })).closest("article")!;
    const deleteButton = localCard.querySelector<HTMLButtonElement>("button.danger")!;
    deleteButton.focus();
    fireEvent.click(deleteButton);

    fireEvent.keyDown(screen.getByRole("dialog", { name: "删除角色" }), { key: "Escape" });

    await waitFor(() => expect(screen.queryByRole("dialog", { name: "删除角色" })).not.toBeInTheDocument());
    await waitFor(() => expect(deleteButton).toHaveFocus());
    expect(api.remove).not.toHaveBeenCalled();
  });

  it("exposes loading and operation state through aria-busy", async () => {
    let finishList!: (entries: CharacterCatalogEntry[]) => void;
    const { api } = makeApi();
    vi.mocked(api.list).mockImplementation(() => new Promise((resolve) => { finishList = resolve; }));
    render(<AppearanceCenter api={api} />);
    const main = screen.getByRole("main");
    expect(main).toHaveAttribute("aria-busy", "true");

    finishList([bundled, local, broken]);
    await screen.findByRole("heading", { name: "官方占位" });
    expect(main).toHaveAttribute("aria-busy", "false");
  });

  it("uses alert for errors and status for ordinary feedback", async () => {
    const { api, change } = makeApi();
    render(<AppearanceCenter api={api} />);
    const localCard = (await screen.findByRole("heading", { name: "我的角色" })).closest("article")!;
    fireEvent.click(localCard.querySelector<HTMLButtonElement>("button.primary")!);
    const request = vi.mocked(api.requestSelection).mock.calls[0][0];
    change({ id: "personal", source: "local", requestId: request.requestId, ok: false, error: "切换已取消" });
    expect(await screen.findByRole("alert")).toHaveTextContent("切换已取消");

    fireEvent.click(screen.getByRole("button", { name: "导入角色包" }));
    expect(await screen.findByRole("status")).toHaveTextContent(/角色包导入完成/);
  });

  it("offers a qipet import action in the empty local state", async () => {
    const { api } = makeApi(true, "_placeholder", []);
    render(<AppearanceCenter api={api} />);
    expect(await screen.findByText("尚无本机私用角色。")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "导入 .qipet" }));
    expect(api.importPackage).toHaveBeenCalledTimes(1);
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
    expect(await screen.findByLabelText("没有预览图")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "刷新" }));

    await waitFor(() => expect(screen.getByAltText("官方占位 预览")).toHaveAttribute("src", "/characters/official/preview.png?v=1.1.0"));
  });
});
