# 代码签名与 SmartScreen

当前 `0.1.0` NSIS 安装包未签名，`Get-AuthenticodeSignature` 返回 `NotSigned`。内部测试人员必须先使用发布目录中的 `SHA256SUMS.txt` 核对：

```powershell
Get-FileHash '.\release\Desk Pet Framework_0.1.0_x64-setup.exe' -Algorithm SHA256
Get-AuthenticodeSignature '.\release\Desk Pet Framework_0.1.0_x64-setup.exe'
```

不要绕过 SmartScreen、杀毒软件或企业策略。本机未出现警告不代表其他电脑不会出现。

公开发布前由项目所有者完成：购买或申请可信代码签名证书、安全保存私钥、签名 EXE 和最终安装包、验证时间戳与证书链。Codex 不自动申请证书或处理私钥。

签名后必须重新执行哈希与清单生成、干净 Windows 10/11 安装、SmartScreen、升级、卸载、杀毒软件扫描和签名完整性测试。签名会改变文件哈希，旧校验和不能继续使用。
