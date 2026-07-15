# 安装说明

当前本地 RC 的版本化内部安装包为 `七酱桌宠_0.1.0-beta.1-rc.1_x64-setup.exe`，对外文件名为 `七酱桌宠.exe`。该 RC 尚未创建标签，也不代表公开测试 Gate 已通过。

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

当前 NSIS 使用 `currentUser` 和默认 LocalAppData 安装策略。尚未通过真实 QA 证明图形界面支持自定义 Program Files、中文或长安装路径；纯路径函数测试不能替代真实 NSIS 安装测试。
