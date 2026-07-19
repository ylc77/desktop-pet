# 0.2.0 正式版验收清单

本清单是当前 `0.2.0` 正式版候选 Gate 的状态总表。状态只能填写 `passed`、`failed`、`blocked` 或 `not_executed`，并必须附带当前候选的环境结果 JSON 或真实人工记录。自动化、当前机器、Sandbox、Windows 10 VM、Windows 11 VM 和真实硬件结果不得互相替代。

当前结论：**CANDIDATE / NOT_PUBLISHED**。生产 Updater 密钥、公钥和 GitHub Releases endpoint 已确认；`0.2.0` 必须在干净提交上重新构建、签名并验证远端资产。Windows Authenticode 仍为 `NotSigned`。按项目所有者决定，本候选不重复真实 A → B 更新生命周期；该项保持 `not_executed`，不得伪造成通过。

## A. 必须通过

| ID | 验收项目 | 当前状态 | 所需证据 |
|---|---|---|---|
| automatic-release | 自动测试及普通 Release 构建 | passed（需在候选 commit 重跑） | Safe QA 环境结果、命令日志、manifest |
| updater-foundation | Updater/Process 插件、状态机和用户入口 | passed（需在候选 commit 重跑） | 单元测试、Rust 测试、静态配置检查 |
| updater-production-config | 生产 updater 公钥和 HTTPS endpoint | blocked | 用户确认、外部私钥验证、公钥指纹、最终配置 |
| updater-artifacts | 版本化安装包、`.sig`、含实际 size 的 `latest.json` 与 manifest | blocked | 外部生产公钥真实验签及最终产物验证结果 |
| application-updater-e2e | A 的应用内 updater 下载、安装并重启到 B，且数据保留 | blocked | 原始报告 SHA-256 绑定；严格 integer schema；远端 latest 与本地 B/生产公钥绑定；按 A pending→B restart→B confirmed 顺序观察；只执行 A；设置、完整角色包、启动项和开始菜单均保留；直接安装器覆盖结果不能替代 |
| current-machine-lifecycle | 当前候选的真实安装、启动、退出和卸载 | not_executed | 当前候选独立报告；历史结果不能替代 |
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
| diagnostics-privacy | 诊断导出脱敏且不自动上传 | passed（需在候选 commit 重跑） | 自动测试与人工检查导出内容 |
| high-severity-clear | 严重和高优先级问题清零 | blocked | 当前候选完整生命周期、updater 及干净系统结果 |

## B. 强烈建议

- [ ] 可信 Windows 代码签名、SHA-256 摘要和时间戳。
- [ ] 生产 Tauri Updater 私钥的至少 16 字符密码、无 reparse point 的仓库外存储与至少两份离线备份。
- [ ] 记录真实 SmartScreen 首次下载体验。
- [ ] Defender 之外的误报检查；不得上传私人构建，除非用户明确授权。
- [ ] Windows 10/11 各自独立干净 VM、普通用户和管理员权限对比。
- [ ] 多组混合 DPI、显示器热插拔、中文用户名、中文/空格/长路径。

未完成 B 项不会单独把所有工程结果判为失败，但必须在发布说明中公开风险。

## C. 可延期但必须说明

- ARM64：当前只验证 x64。
- 完全离线 WebView2：当前 `downloadBootstrapper` 不包含离线 Runtime。
- Microsoft Store、macOS、Linux：当前未实现。

自动更新不属于“可延期且已完成”：生产配置虽已确认，但远端与端到端验证未完成，仍是公开测试 Gate 的阻塞项。

## 证据要求

每份 `environment-result.json` 必须包含环境 ID、Windows 版本、架构、是否 VM、时间、Git commit、安装包 SHA-256、实际命令、检查状态和证据说明。统一审核命令：

```powershell
.\scripts\windows\audit-public-beta-readiness.ps1
```

Updater 专项清单见 [UPDATER_QA.md](UPDATER_QA.md)。审核必须显式接收仓库外生产公钥并真实验证安装包签名；远端发布后还必须通过 `-ReleaseExpectation Present -Anonymous` 复核公开资产。若检测到 `NOT_CONFIGURED`、缺少 `.sig`/`latest.json`、签名未通过、Windows `NotSigned` 风险或没有 A → B 真实证据，必须保留对应 `blocked`/`failed`/`not_executed` 状态，不得通过手工改报告绕过。
