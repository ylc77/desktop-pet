# 隐私说明

七酱桌宠 0.1.0-beta.1-rc.1 是离线优先的本地 Windows 应用。

- 不包含遥测、广告、账号、支付、云数据库或在线同步。
- 不上传设置、日志、角色资源、崩溃报告或设备信息。
- 核心应用运行不主动访问网络。
- 当目标电脑缺少 Microsoft Edge WebView2 Runtime 时，NSIS 的 `downloadBootstrapper` 会访问 Microsoft 的下载服务；这是当前安装流程唯一可能需要的网络活动。
- 设置保存在 `%APPDATA%\dev.deskpet.framework\`。
- 日志保存在 `%LOCALAPPDATA%\dev.deskpet.framework\logs\`，单文件最多 1 MiB，最多保留 5 个轮转文件。
- 卸载默认保留设置和日志，避免未经用户许可删除本地数据。彻底清除只能由用户明确操作这两个应用专属目录。

当前没有在线隐私请求或客服系统。公开测试人员应在提交日志前自行检查并仅交给项目维护者；不要公开包含用户名或本地路径的原始日志。
