# Updater QA

当前 updater 基础为 `INTEGRATED / NOT_CONFIGURED`。本清单用于自动化、临时测试签名和后续真实版本 A → B 验证；前两者不能替代真实端到端升级。

两种升级证据必须严格区分：

- `run-public-beta-qa.ps1 -Mode Upgrade` 直接依次运行 A、B 两个 NSIS 安装器，只验证覆盖安装兼容性；报告固定为 `evidenceType=direct_installer_overlay`。
- `run-public-beta-qa.ps1 -Mode ApplicationUpdater` 只允许运行 A 安装器。B 安装器仅用于版本、哈希和签名校验，必须由 A 的 About/Update UI 发现、下载并安装；通过报告固定为 `evidenceType=application_updater_e2e`。

Public Beta Gate 的独立必需项 `application-updater-e2e` 只接受第二种报告，并同时要求来源报告、环境和检查项都是 `passed`。直接覆盖安装结果永远不能满足该项。

提供外部生产公钥时，应用内 updater QA 会分别约束 A/B manifest 的 `artifactFile` 和 `signatureFile` 为纯文件名，将两个 artifact 的 SHA-256 分别绑定到传入的 A/B 安装包，并对 A、B 两组 artifact/`.sig` 都执行真实密码学验签；任意一组缺失、路径越界、哈希不符或验签失败都会在安装 A 之前终止。

真实运行还会在安装 A 前从 A manifest 的 HTTPS endpoint 下载当前 `latest.json`，并将远端的 version、platform、URL、size 和 signature 严格绑定到本地候选 B 与外部生产公钥。`-WhatIf` 不联网，只明确记录这一真实运行计划。

“应用内更新”证据必须按顺序观察到：A 仍在运行且注册表仍为 A 时写入 `pendingUpdateVersion=B`；随后 A PID 退出、B 的新 PID 与唯一 B 安装记录出现；最后 B 写入 `lastConfirmedUpdateVersion=B` 并清空 pending。轮询使用明确阶段机，逆序状态、只在 B 期间出现 pending、或只看到注册表版本/PID 均不得通过，因此操作员手动运行 B 安装器不能替代 updater UI 流程。

Gate 会按汇总报告记录的相对路径和 SHA-256 重新读取 `application-updater-result.json`，并要求报告 schema 为真实 JSON 整数 `1`、`phase=completed`、`whatIf=false`、无失败对象且最终探针成功。它还会独立检查只执行 A、A/B 密码学验签、远端候选与本地 B 的文件名/大小/哈希绑定、有序 pending→restart→confirmed，以及 B 进程/安装记录、设置、完整导入角色包、精确启动项和开始菜单快捷方式全部通过。最小 synthetic raw、仅有标签的 summary 或字符串形式 schema 均不能通过。

脚本在正常可解析的 `OutputDirectory` 中为路径校验和运行失败写入原始报告；若输出目录自身无法初始化，则尽最大可能改写到仓库忽略的安全 fallback 结果目录。失败消息会脱敏盘符正反斜杠路径、`file://` URI 与 UNC 路径，且返回非零退出码。

## 自动化与静态检查

- [ ] Updater 与 Process 插件版本兼容当前 Tauri 2，并只注册一次。
- [ ] capability 不开放 `updater:default`，前端只调用受控 Rust updater 命令；Process 只开放安装命令返回时后备重启所需的 `process:allow-restart`，普通 UI 没有任意进程执行能力。
- [ ] 普通配置 `createUpdaterArtifacts=false`，无需秘密即可构建。
- [ ] 签名构建 overlay 设置 `createUpdaterArtifacts=true` 和 Windows `passive`。
- [ ] 缺 endpoint 或公钥时状态为 `NOT_CONFIGURED`，启动不发请求，手动检查给出明确提示。
- [ ] Production 只接受 HTTPS，拒绝 HTTP、示例域名、本地地址和空公钥。
- [ ] 私钥不在仓库、tracked/staged diff、Release、QA 或日志中。
- [ ] `latest.json` 为 UTF-8 无 BOM、有效 SemVer，signature 与 `.sig` 正文一致，`platforms.<target>.size` 等于安装包实际字节数。
- [ ] 安装包文件名包含精确目标版本；下载 URL 末段与实际版本化文件名完全相同；`.sig` 文件名严格为 `<安装包>.sig`。
- [ ] `create`、确认执行后的 `prepare`、签名 `build` 和 `verify-release-artifacts -RequireUpdater` 都用外部公钥对实际安装包与 `.sig` 做真实密码学验签；错误公钥或篡改文件失败。
- [ ] `validate-latest-json` 的 artifact/signature/public-key 三件套只能全部提供或全部省略；生产 QA 必须全部提供并得到 `CryptographicSignatureVerified=true`。
- [ ] manifest commit 与 HEAD 一致，公钥指纹存在，不含私钥信息或绝对路径。
- [ ] 版本 A/B 不同且 B > A，identifier 与 updater 公钥相同。

## 状态机与 UI 单元测试

- [ ] 无更新、相同版本和低版本不会提示升级；预发布 SemVer 比较正确。
- [ ] 发现更高版本显示当前/目标版本、发布日期、说明和可用大小。
- [ ] 自动检查最多每 24 小时一次，手动检查绕过节流。
- [ ] 稍后提醒与跳过当前版本有效；更高版本仍提示；手动检查可看见跳过版本。
- [ ] 重复检查合并；下载中不再次检查；同一时间只有一个下载任务。
- [ ] 已知长度、未知长度、下载中断和取消状态正确，不伪造 100%。
- [ ] 404、超时、非法 JSON、空 signature、签名错误、权限错误和安装失败分类正确。
- [ ] 自动失败只写脱敏日志，手动失败显示简洁错误且可以重试。
- [ ] 严格设置写入或安装前日志刷新失败会阻止安装，旧应用继续运行，`pendingUpdateVersion` 不留下伪成功值。
- [ ] Windows 正常路径由 updater 启动 passive NSIS 后终止式交接，`on_before_exit` 执行日志刷新和应用清理，旧进程不残留；NSIS 自动启动新版本。
- [ ] 安装失败不重启；安装命令异常返回时才使用受控 relaunch 后备；新进程按实际版本确认并清理 pending，且不会形成重启循环。
- [ ] 更新前刷新设置；更新后保留位置、缩放、角色、自动启动和更新偏好。
- [ ] 关闭面板不丢任务；React 卸载后不 setState；退出清理监听器。
- [ ] About 版本正确，主窗口右键、托盘和设置入口指向同一更新任务。
- [ ] Production 不显示内部 updater 调试入口。

## 临时签名集成测试

临时测试目录内可以生成一次性测试密钥与安装包副本，验证：

- [ ] 正确公钥验证成功。
- [ ] 错误公钥验证失败。
- [ ] 文件修改后验证失败。
- [ ] `.sig` 正文正确写入并由 `latest.json` 验证器接受。
- [ ] URL 别名、版本不精确、`.sig` 名称错误、元数据 size 错误或只提供三件套中的一部分均被拒绝。
- [ ] 测试密钥和临时产物完成后删除，未被 Git 跟踪。

临时签名通过只能记为 `LOCAL_SIGNING_VERIFIED`，不能记为生产密钥备份完成或 `END_TO_END_UPDATE_PASSED`。

## 真实版本 A → B

在可恢复、可丢弃的 Windows 10/11 环境中，由用户确认后执行：

先做无安装副作用的完整预览：

```powershell
.\scripts\windows\run-public-beta-qa.ps1 `
  -Mode ApplicationUpdater `
  -PreviousInstallerPath '<version-A-installer>' `
  -InstallerPath '<version-B-installer-reference>' `
  -PreviousUpdaterManifestPath '<version-A-updater-manifest>' `
  -UpdaterManifestPath '<version-B-updater-manifest>' `
  -UpdaterPublicKeyPath '<external-production-public-key>' `
  -OutputDirectory '.\qa-results\public-beta-application-updater' `
  -WhatIf
```

真实运行还必须在明确的可丢弃环境中设置 `DESK_PET_QA_CLEAN_ENVIRONMENT=1`。脚本安装并启动 A 后，会要求操作员先准备非敏感设置和测试角色，再在 A 的 UI 手工触发“检查 → 下载 → 安装”。脚本最多轮询 10 分钟，验证 A 记录出现、A PID 退出、B 记录出现、新 PID 启动、单一卸载记录、设置/角色保持及启动项不重复；它不会启动传入的 B 安装器路径。

默认在通过后保留 B 供人工检查。只有显式增加 `-UninstallAfterUpdate` 才会在操作员通过托盘正常退出 B 后运行注册卸载器，并使用既有的最长 60 秒有界清理轮询；失败时不自动删除文件或注册表来制造通过结果。无论成功、失败或 `-WhatIf`，原始结果都写入 `application-updater-result.json`。

1. 安装真实版本 A，记录安装包哈希、签名、公钥指纹、安装记录和进程。
2. 修改窗口位置、缩放、自动启动和自动检查，并导入一个测试角色包。
3. 让 A 从用户确认的 HTTPS endpoint 发现由同一 updater 私钥签署的 B。
4. 验证更新说明、已知/未知下载进度、签名、严格设置保存、被动安装、旧进程退出、NSIS 自动启动和 pending 版本确认。
5. 确认版本变为 B，设置、角色与更新偏好保留；单实例、托盘、`desktop_pet.exe` 启动项正常，旧版本进程不残留。
6. 确认只有一个安装记录、快捷方式和启动项，没有旧程序残留。
7. 卸载 B，使用最多 60 秒的有界轮询检查进程、记录、目录、启动项和开始菜单。

同时分别验证 endpoint/JSON 404、非法 JSON、断网、下载中断、错误签名、被篡改文件、相同版本、低版本和临时不可用。每个失败场景都必须保持旧应用可运行、设置不丢失、不无限重试、不反复弹窗、不留下半安装状态。

## 当前未执行

- 生产密钥签名
- 正式 HTTPS endpoint
- 两个真实版本构建和托管
- 下载、安装、重启和升级后验证
- Windows Authenticode、SmartScreen、Defender 和干净 Windows 10/11

因此 Public Beta Gate 当前必须为 `BLOCKED`。
