# 公开测试版验收清单

本清单是 `0.1.0` 公开测试版 Gate 的唯一状态总表。状态只能填写 `passed`、`failed`、`blocked` 或 `not_executed`，并必须附带环境结果 JSON 或真实人工记录。自动化、当前机器、Sandbox、Windows 10 VM、Windows 11 VM 和真实硬件结果不得互相替代。

当前结论：**NOT_READY**。`0.1.0-beta.1-rc.1` 已增加卸载清理轮询并仅作为本地验证产物；真实 CurrentMachine 卸载复测通过前，不创建版本标签或公开测试版目录。

## A. 必须通过

| ID | 验收项目 | 当前状态 | 所需证据 |
|---|---|---|---|
| automatic-release | 自动测试及 Release 构建 | passed（需在候选 commit 重跑） | Safe QA 环境结果、命令日志、manifest |
| current-machine-lifecycle | 当前机器真实安装、启动、退出和卸载 | failed | 最新卸载报告显示 3 项残留 |
| clean-windows-11 | 干净 Windows 11 生命周期 | blocked | Sandbox/VM 独立结果 |
| clean-windows-10 | 干净 Windows 10 生命周期 | blocked | Windows 10 VM 独立结果 |
| webview2-online | 缺失 WebView2 且联网 | not_executed | 隔离环境结果 |
| webview2-offline | 缺失 WebView2 且断网 | not_executed | 隔离环境结果 |
| upgrade-0.1x | 旧 0.1.x 覆盖升级 | blocked | 两个不同版本安装包和可丢弃环境 |
| settings-migration | 设置保留和迁移 | not_executed | 升级前后设置证据 |
| no-duplicates | 无重复启动项、安装或卸载记录 | not_executed | 升级结果 |
| single-instance | 单实例 | passed（当前机器） | CurrentMachine 命令日志 |
| autostart | 开机启动 | not_executed | 启用/禁用和重启记录 |
| restart | Windows 重启后运行 | not_executed | 重启前后状态文件 |
| sleep-wake | 睡眠和唤醒 | not_executed | 人工记录 |
| dpi-basic | 基本真实 DPI | blocked | 真实设备记录 |
| dual-monitor | 真实双显示器 | blocked | 真实双屏记录和截图 |
| stability-8h | 8 小时稳定性 | not_executed | CSV、摘要、分析和操作记录 |
| defender | Defender 检查 | not_executed | 扫描时间与结果 |
| manifest-hash | Manifest 与安装包哈希一致 | passed（需候选 commit 重跑） | Safe QA 结果 |
| public-docs | 发布、隐私和已知问题文档 | passed（文档基线） | 本目录文档审查 |
| high-severity-clear | 严重和高优先级问题清零 | failed | 卸载残留尚未解决 |

## B. 强烈建议

- [ ] 可信 Windows 代码签名、SHA-256 摘要和时间戳。
- [ ] 记录真实 SmartScreen 首次下载体验。
- [ ] Defender 之外的误报检查；不得上传私人构建，除非用户明确授权。
- [ ] Windows 10/11 各自独立干净 VM、普通用户和管理员权限对比。
- [ ] 多组混合 DPI、显示器热插拔、中文用户名、中文/空格/长路径。

未完成 B 项不会单独把所有工程结果判为失败，但必须在发布说明中公开风险。

## C. 可延期但必须说明

- ARM64：当前只验证 x64。
- 完全离线 WebView2：当前 `downloadBootstrapper` 不包含离线 Runtime。
- 自动更新、Microsoft Store、macOS、Linux：当前未实现。

## 证据要求

每份 `environment-result.json` 必须包含环境 ID、Windows 版本、架构、是否 VM、时间、Git commit、安装包 SHA-256、实际命令、检查状态和证据说明。统一审核命令：

```powershell
.\scripts\windows\audit-public-beta-readiness.ps1
```
