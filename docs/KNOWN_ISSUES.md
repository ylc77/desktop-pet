# 已知问题

## 严重/高优先级

### 卸载后程序和注册信息残留

- 状态：开放，阻塞公开测试版。
- 环境：当前 Windows 11 x64，Desk Pet Framework 0.1.0。
- 真实结果：卸载器进程返回后，卸载注册表记录、`%LOCALAPPDATA%\Desk Pet Framework` 和开始菜单项仍存在；应用进程与开机启动项为 0。
- 证据：`qa-results-current-machine-uninstall-only-real`（本地 QA 目录，不提交 Git）。
- 注意：不得手工删除注册表或未知文件来把该测试标记为通过。需要修复或确认 NSIS 卸载器子进程等待/交互语义后重新执行真实卸载。

## 公开测试风险

- 安装包当前 `NotSigned`，存在 SmartScreen 和未知发布者风险。
- 干净 Windows 10/11、WebView2 缺失联网/断网、真实升级尚未执行。
- 真实多显示器、混合 DPI、睡眠、唤醒、重启和远程桌面尚未执行。
- 尚无完整 8 小时稳定性结果。
- 当前素材是中性占位角色。

## 可延期能力

ARM64、完全离线 WebView2、自动更新、Microsoft Store、macOS 和 Linux 不在当前版本范围。
