# 安装说明

`0.2.0` 是稳定渠道正式版目标。生产 Updater 公钥与 HTTPS endpoint 已配置；最终安装包只有在签名、哈希、Manifest、本地启动和远端资产验证通过后才允许发布。本版本按项目所有者决定不重复真实 A → B 更新生命周期。

1. 确认系统为 Windows 10/11 x64，并准备联网环境以便缺失时下载 WebView2。
2. 从可信渠道取得安装包和 `SHA256SUMS.txt`。
3. 在 PowerShell 中核对：

```powershell
Get-FileHash '.\七酱桌宠.exe' -Algorithm SHA256
Get-AuthenticodeSignature '.\七酱桌宠.exe'
```

4. 只有哈希与发布清单一致时才运行安装包。
5. 当前安装包未签名。若 SmartScreen 出现未知发布者提示，应停止并向提供安装包的项目维护者核对哈希；本文档不指导绕过 SmartScreen。
6. 安装完成后从开始菜单启动。最终用户不需要 Node.js、Rust 或源码。

当前 NSIS 使用 `currentUser` 和默认 LocalAppData 安装策略，安装及卸载向导显式使用简体中文且不显示语言选择器。安装后的主程序文件名为 `desktop_pet.exe`。中文用户名、长路径和不同 Windows 版本仍需继续积累真实环境证据；纯路径函数测试不能替代真实 NSIS 安装测试。

生产签名构建默认自动检查更新，用户可关闭；更新不会静默下载或安装，必须点击“立即更新”。普通非 updater 构建仍保持不联网。网络与签名说明见 [AUTO_UPDATE.md](AUTO_UPDATE.md)。
