# 代码签名与 SmartScreen

当前 `0.1.0` NSIS 安装包未签名，`Get-AuthenticodeSignature` 返回 `NotSigned`。内部测试人员必须先使用发布目录中的 `SHA256SUMS.txt` 核对：

```powershell
Get-FileHash '.\release\七酱桌宠.exe' -Algorithm SHA256
Get-AuthenticodeSignature '.\release\七酱桌宠.exe'
```

不要绕过 SmartScreen、杀毒软件或企业策略。本机未出现警告不代表其他电脑不会出现。

Tauri Updater 签名与 Windows Authenticode 是两套独立机制：Updater 公钥用于验证更新包完整性和发布授权，Windows 代码签名用于可信发布者身份、证书链和 SmartScreen。生产 Updater 密钥已经配置；即使 `.sig` 验证通过，Windows 状态仍会保持 `NotSigned`，直到项目所有者使用可信代码签名证书签署最终文件。

公开发布前由项目所有者完成：购买或申请可信代码签名证书、安全保存私钥、签名 EXE 和最终安装包、验证时间戳与证书链。Codex 不自动申请证书或处理私钥。

签名后必须重新执行哈希与清单生成、干净 Windows 10/11 安装、SmartScreen、升级、卸载、杀毒软件扫描和签名完整性测试。签名会改变文件哈希，旧校验和不能继续使用。

若同一安装包用于 Tauri Updater，Windows 代码签名和时间戳完成后还必须为最终文件重新生成 Updater `.sig`，再重建 `latest.json`、`SHA256SUMS.txt` 和 release manifest。旧 `.sig` 不能验证字节已经改变的文件。完整顺序见 [Windows 代码签名待办](WINDOWS_CODE_SIGNING_TODO.md) 与 [Updater 发布流程](UPDATER_RELEASE_PROCESS.md)。

## 公开测试版签名准备清单

- [ ] 由项目所有者选择可信的组织或个人代码签名证书类型。
- [ ] 私钥保存在受控硬件或安全证书存储中，不进入仓库、日志或聊天。
- [ ] 使用 Windows SDK `signtool` 和 SHA-256 摘要算法。
- [ ] 配置可信 RFC 3161 时间戳服务，并验证时间戳和证书链。
- [ ] 签名应用 EXE 和最终 NSIS 安装包。
- [ ] 签名后重新计算 SHA-256、重建 `SHA256SUMS.txt` 和 release manifest。
- [ ] 在干净 Windows 10/11 重新执行安装、升级、卸载、Defender 和 SmartScreen QA。

未签名审核必须记录 `Unsigned public beta risk`。未签名不会让其他 QA 自动跳过，但默认不能判为 `PUBLIC_BETA_READY`；Codex 不生成自签名证书冒充公开发布证书。
