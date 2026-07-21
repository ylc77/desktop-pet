import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ContextMenu } from "../src/components/ContextMenu/ContextMenu";
import { DEFAULT_SETTINGS } from "../src/core/settings/settingsSchema";

const position = { x: 120, y: 80 };

afterEach(() => {
  cleanup();
});

describe("desktop pet context menu", () => {
  it("uses the selected compact order and removes the About entry", () => {
    render(
      <ContextMenu
        position={position}
        settings={DEFAULT_SETTINGS}
        updateBusy={false}
        onPatch={vi.fn()}
        onAction={vi.fn()}
        onClose={vi.fn()}
      />,
    );

    const menu = screen.getByRole("menu");
    expect(Array.from(menu.querySelectorAll("button")).map((item) => item.textContent)).toEqual([
      "暂停动画",
      "隐藏桌宠",
      "外观中心",
      "设置",
      "开机启动",
      "检查更新",
      "退出",
    ]);
    expect(screen.queryByText("关于七酱桌宠")).not.toBeInTheDocument();
    expect(screen.queryByText("退出七酱桌宠")).not.toBeInTheDocument();
  });

  it("supports keyboard navigation and Escape", async () => {
    const onClose = vi.fn();
    render(
      <ContextMenu
        position={position}
        settings={DEFAULT_SETTINGS}
        updateBusy={false}
        onPatch={vi.fn()}
        onAction={vi.fn()}
        onClose={onClose}
      />,
    );

    const pause = screen.getByRole("menuitemcheckbox", { name: "暂停动画" });
    const hide = screen.getByRole("menuitem", { name: "隐藏桌宠" });
    await waitFor(() => expect(pause).toHaveFocus());
    fireEvent.keyDown(pause, { key: "ArrowDown" });
    expect(hide).toHaveFocus();
    fireEvent.keyDown(hide, { key: "Escape" });
    expect(onClose).toHaveBeenCalledOnce();
  });

  it("closes before dispatching actions and setting toggles", () => {
    const calls: string[] = [];
    const onPatch = vi.fn(() => calls.push("patch"));
    const onAction = vi.fn(() => calls.push("action"));
    const onClose = vi.fn(() => calls.push("close"));
    render(
      <ContextMenu
        position={position}
        settings={DEFAULT_SETTINGS}
        updateBusy={false}
        onPatch={onPatch}
        onAction={onAction}
        onClose={onClose}
      />,
    );

    fireEvent.click(screen.getByRole("menuitem", { name: "外观中心" }));
    expect(calls).toEqual(["close", "action"]);
    expect(onAction).toHaveBeenCalledWith("appearance");

    calls.length = 0;
    fireEvent.click(screen.getByRole("menuitemcheckbox", { name: "开机启动" }));
    expect(calls).toEqual(["close", "patch"]);
    expect(onPatch).toHaveBeenCalledWith({ autostart: !DEFAULT_SETTINGS.autostart });
  });

  it("closes when the user clicks outside the menu or moves focus to the desktop", () => {
    const onClose = vi.fn();
    const { unmount } = render(
      <ContextMenu
        position={position}
        settings={DEFAULT_SETTINGS}
        updateBusy={false}
        onPatch={vi.fn()}
        onAction={vi.fn()}
        onClose={onClose}
      />,
    );

    const backdrop = screen.getByRole("menu").parentElement;
    expect(backdrop).not.toBeNull();
    fireEvent.pointerDown(backdrop!);
    expect(onClose).toHaveBeenCalledOnce();
    unmount();

    const closeOnBlur = vi.fn();
    render(
      <ContextMenu
        position={position}
        settings={DEFAULT_SETTINGS}
        updateBusy={false}
        onPatch={vi.fn()}
        onAction={vi.fn()}
        onClose={closeOnBlur}
      />,
    );
    fireEvent.blur(window);
    expect(closeOnBlur).toHaveBeenCalledOnce();
  });

  it("opens against the viewport edge instead of covering the pet around the pointer", async () => {
    const rect = vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockReturnValue({
      width: 124,
      height: 288,
      top: 0,
      right: 124,
      bottom: 288,
      left: 0,
      x: 0,
      y: 0,
      toJSON: () => ({}),
    });

    render(
      <ContextMenu
        position={{ x: 120, y: 80 }}
        settings={DEFAULT_SETTINGS}
        updateBusy={false}
        onPatch={vi.fn()}
        onAction={vi.fn()}
        onClose={vi.fn()}
      />,
    );

    await waitFor(() => {
      expect(screen.getByRole("menu")).toHaveStyle({ left: `${window.innerWidth - 132}px` });
    });
    rect.mockRestore();
  });

  it("keeps the native tray fallback aligned with the new wording", () => {
    const rust = readFileSync(resolve(import.meta.dirname, "../src-tauri/src/lib.rs"), "utf8");
    const start = rust.indexOf("fn build_native_menu");
    const end = rust.indexOf("fn refresh_tray_menu", start);
    const menuBuilder = rust.slice(start, end);
    expect(menuBuilder).not.toContain("关于七酱桌宠");
    expect(menuBuilder).not.toContain("退出七酱桌宠");
    expect(menuBuilder).toContain('"退出"');
  });
});
