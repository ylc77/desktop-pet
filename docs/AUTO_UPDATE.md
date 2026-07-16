# 自动更新说明

七酱桌宠 `0.1.0` 已接入 Tauri 2 Updater 与 Process 插件的安全更新基础，但当前生产 updater 公钥和 HTTPS endpoint **尚未配置**。因此当前状态是 `INTEGRATED / NOT_CONFIGURED`，不是“自动更新已公开可用”，公开测试版 Gate 仍为 `BLOCKED`。

## 当前行为

- 更新渠道固定为 `beta`；普通用户暂时不能切换渠道。
- 普通未配置构建不会在启动后请求网络。手动检查会明确显示“更新服务尚未配置”。
- 配置完成后，启动自动检查会延迟 10–30 秒，并且最多每 24 小时一次；手动检查不受该节流限制。
- 自动检查可以在设置中关闭。自动检查失败只写入脱敏日志，不弹出阻塞窗口。
- 检查到新版本后由用户选择“立即更新”“稍后提醒”或“跳过此版本”。不会静默下载或静默安装。
- 跳过只针对一个具体版本；更高版本仍会提示，手动检查仍可看见被跳过的版本。
- 下载长度已知时显示真实进度；服务端不提供长度时显示不确定进度，不伪造百分比。

Rust 更新封装只在构建同时提供 `QIJIANG_UPDATER_ENDPOINT` 与 `QIJIANG_UPDATER_PUBLIC_KEY` 时启用；缺少任意一项都返回 `NOT_CONFIGURED`，不会尝试网络请求。它们都是随应用发布的公开验证配置，不得包含私钥或访问令牌。

## 更新状态

更新流程使用单一任务和以下状态：

`disabled` → `idle` → `checking` → `upToDate` 或 `available` → `downloading` → `readyToInstall` → `installing` → `restarting`

“稍后提醒”保留 `available` 状态但不下载；用户明确取消尚未开始的 pending 更新时进入 `cancelled`；可恢复错误进入 `error`。重复点击会复用正在执行的检查，同一时间不会启动多个下载或安装任务。

设置只保存更新策略和非敏感结果：

- `lastCheckAt`
- `lastAvailableVersion`
- `skippedVersion`
- `lastFailureCategory`
- 自动检查开关

不会保存带 query 的完整下载 URL、访问令牌或签名私钥信息。

## 安全边界

- Production 只接受 HTTPS endpoint。
- 前端通过受控 Rust 命令检查、下载和安装，不开放 `updater:default`；capability 只额外允许 Process 插件的 `process:allow-restart` 和项目自有 updater/诊断命令。
- 禁止 `dangerousInsecureTransportProtocol`，禁止关闭 Tauri 更新签名验证。
- `latest.json` 的 `signature` 必须是 `.sig` 文件的实际文本，不是文件路径或 URL。
- 更新器只使用版本化安装包，例如 `七酱桌宠_0.2.1-beta.1_x64-setup.exe`，不使用可能被覆盖的 `七酱桌宠.exe` 别名；URL 末段必须与实际安装包文件名完全相同，`.sig` 必须命名为 `<安装包>.sig`。
- `latest.json` 的 `platforms.<target>.size` 来自最终安装包的实际字节数。生产 create、prepare、签名 build 和 Gate 都必须使用指定公钥对实际安装包与 `.sig` 做密码学验签，不能用“文件存在”或公钥指纹匹配代替。
- 更新签名验证保护下载文件的完整性和发布授权；它不提供 Windows“可信发布者”身份。当前 Windows Authenticode 状态仍是 `NotSigned`。

## 安装与恢复

Windows 更新安装模式为 `passive`。开始安装前，应用使用严格写入路径保存设置、窗口位置、缩放、当前角色 ID、更新偏好、`pendingUpdateVersion` 和必要日志；任何原生设置写入或日志刷新失败都会阻止安装，不会只写警告后继续。

正常 Windows 路径是终止式安装交接：Tauri Updater 启动被动 NSIS，`on_before_exit` 刷新日志并执行应用退出清理，旧进程随后退出；NSIS 替换文件后自动启动新程序。只有安装命令在该路径之外返回时，受控 Process relaunch 才作为后备。新进程会确认实际版本是否等于 `pendingUpdateVersion`，记录确认结果并清理一次性 pending 状态，从而避免旧进程残留、虚假的“已重启”状态和重启循环。真实版本 A → B 更新、NSIS 自动启动、进程退出、单实例、开机启动和卸载仍需在隔离 Windows 环境中验证。

## 网络与隐私

只有在配置正式 HTTPS 更新源且自动检查开启，或用户主动手动检查时，应用才会访问更新服务。请求会向托管服务暴露网络连接通常包含的信息（例如 IP 地址）；七酱桌宠不附带账号、角色资源、设置、日志或诊断包。

诊断信息只能由用户主动导出到本地，不会自动上传。详见 [隐私说明](PRIVACY.md) 与 [关于和诊断](ABOUT_AND_DIAGNOSTICS.md)。

## 当前尚未完成

- 生产 updater 密钥生成与离线备份
- 正式 HTTPS endpoint 和托管平台选择
- 使用最终公钥构建版本 A 与版本 B
- 真实下载、安装、重启和升级回滚测试
- Windows 代码签名与 SmartScreen 验证
- 干净 Windows 10/11 完整生命周期测试

完成这些项目并取得可审计证据前，不得宣称自动更新已可公开使用。
