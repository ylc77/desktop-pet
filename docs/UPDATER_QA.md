# Updater QA

当前 updater 基础为 `INTEGRATED / NOT_CONFIGURED`。本清单用于自动化、临时测试签名和后续真实版本 A → B 验证；前两者不能替代真实端到端升级。

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
