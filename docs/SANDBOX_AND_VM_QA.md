# Windows Sandbox 与虚拟机 QA

当前检测：Windows Sandbox 可选功能存在但为 `Disabled`；未自动启用，也未重启电脑。Hyper-V 命令可用但未发现现成 VM；未发现 `vmrun` 或 `VBoxManage`。

## Sandbox

管理员或测试机所有者可在自行启用 Sandbox 后准备：

1. 创建 `C:\DeskPetQA\Input` 和 `C:\DeskPetQA\Results`。
2. 将项目的 `release`、`scripts` 复制到 Input；Input 在 Sandbox 中为只读。
3. 打开 `scripts/windows/sandbox/DeskPetQA.wsb`。
4. 按 Sandbox 终端提示，通过桌宠菜单正常退出。
5. 关闭 Sandbox 前查看主机 Results。

Sandbox 只代表主机当前 Windows 版本。必须单独记录其中 WebView2 实际是否存在；不得将结果描述为同时通过 Windows 10 和 Windows 11。

## 虚拟机

先运行 `scripts/windows/detect-test-environments.ps1`。启动/关闭 VM、创建或恢复快照、挂载共享目录以及在 VM 中安装应用都必须由用户明确授权。推荐分别准备干净 Windows 10 22H2 与 Windows 11 当前受支持版本快照，并将 `qa-results` 导出回主机。
