# Windows 代码签名待办

七酱桌宠 `0.1.0` 的 Windows Authenticode 状态仍为 `NotSigned`。Tauri Updater 安全基础的接入不会改变这一状态，也不会让安装包自动成为 Windows 可信发布者。

## Updater 签名与代码签名

- **Tauri Updater 签名**：应用内置公钥验证下载的更新包是否由对应私钥签署且未被篡改。
- **Windows Authenticode**：Windows 验证发布者证书、文件完整性和可信时间戳，影响安装界面发布者信息与 SmartScreen 体验。

正式公开测试需要分别评估和验证两者。不能用临时、自签名或 Updater 密钥冒充可信 Windows 代码签名证书。

## 项目所有者待办

- [ ] 选择适合个人或组织身份的可信代码签名证书方案。
- [ ] 将私钥保存在受控证书存储、硬件令牌或合规云签名服务中，不进入 Git、脚本、聊天或日志。
- [ ] 使用 SHA-256 文件摘要和可信 RFC 3161 时间戳服务。
- [ ] 签名最终 `desktop_pet.exe` 与最终 NSIS 安装包。
- [ ] 验证签名状态、证书链、时间戳、文件版本和显示名称。
- [ ] 对 Windows 签名后的最终更新文件重新计算 SHA-256。
- [ ] 使用生产 Tauri Updater 私钥重新生成最终文件的 `.sig`。
- [ ] 重新生成 `latest.json`、`SHA256SUMS.txt` 与 release manifest。
- [ ] 在干净 Windows 10/11 重跑安装、升级、更新、卸载、Defender 和 SmartScreen QA。

Windows 签名改变文件字节，所以旧 SHA-256 和旧 updater `.sig` 都不能继续使用。上传顺序必须保证 `latest.json` 只引用完成 Windows 签名、Updater 签名和最终验证的版本化文件。

## 当前发布判断

在可信代码签名决策、SmartScreen 和干净系统结果完成前，报告中必须继续写：

```text
Windows code signature: NotSigned
```

当前 Public Beta Gate 为 `BLOCKED`，不得把“Updater 签名基础已接入”表述为“安装包已签名”或“可以公开分发”。
