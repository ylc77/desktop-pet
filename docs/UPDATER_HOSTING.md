# Updater 托管：GitHub Releases 与待确认的元数据方案

项目所有者已经确认使用公开仓库 `ylc77/desktop-pet` 的 GitHub Releases 托管版本化 Windows 二进制。GitHub Pages 仅是当前建议的 `beta` 元数据托管方案，尚未得到所有者明确确认、启用或实现；建议地址为：

```text
https://ylc77.github.io/desktop-pet/updater/beta/latest.json
```

托管草案位于 `config/updater.github-releases.json`，当前明确为 `enabled: false`，并且 `metadata.ownerConfirmed: false`。它不包含私钥、公钥正文、密码或访问凭据；GitHub Pages 和 Release 尚未创建或修改，因此上面的 URL 只是建议值，不能当作已确认或可用的 Production endpoint。

## 为什么分开托管

GitHub prerelease 不应使用 `/releases/latest`：该路由的语义不保证选中目标 beta prerelease。把 `latest.json` 作为同名滚动 Release asset 反复替换也有非原子窗口，客户端可能在资产更新期间读到旧元数据、404 或缓存副本。

如果所有者后续明确确认 GitHub Pages，建议采用两层模型：

- GitHub Releases 保存不可变的版本化安装包和 `.sig`，tag 固定为 `v<完整 SemVer>`。
- GitHub Pages 保存版本化元数据快照和稳定 beta 指针；先部署 `updater/beta/<version>/latest.json`，最后在同一目录写入临时文件并原子替换 `updater/beta/latest.json`，不直接截断或原地覆盖稳定指针。

示例 `0.2.1-beta.1` 只说明格式，并不表示该版本已经构建或发布：

```text
Release tag: v0.2.1-beta.1
Asset: 七酱桌宠_0.2.1-beta.1_x64-setup.exe
Asset: 七酱桌宠_0.2.1-beta.1_x64-setup.exe.sig
Download: https://github.com/ylc77/desktop-pet/releases/download/v0.2.1-beta.1/<版本化安装包>

Pages snapshot: /desktop-pet/updater/beta/0.2.1-beta.1/latest.json
Pages stable:   /desktop-pet/updater/beta/latest.json
```

不得把公开别名 `七酱桌宠.exe`、滚动同名 Release asset 或 `/releases/latest` 写入 updater 元数据。

## 托管契约

- 仓库必须可匿名访问；发布前用 `gh auth status` 和仓库可见性查询确认操作者身份及 `PUBLIC` 可见性。
- 全部 URL 使用 HTTPS，不含凭据、query 或 fragment。
- Release 先建立为 draft prerelease；tag 和安装包文件名都包含完整 SemVer。
- 安装包、`.sig`、`SHA256SUMS.txt` 和 updater release manifest 使用不可变文件名，不覆盖已存在版本。
- `latest.json` 使用 UTF-8 无 BOM，平台键固定为 `windows-x86_64`，安装模式保持 `passive`；验证器严格拒绝缺失或额外属性、错误 JSON 类型和非 RFC 3339 `pub_date`。
- `latest.json` 中的 URL 文件名、签名正文和 size 必须分别等于实际安装包文件名、`.sig` 正文和最终字节数。
- 上传后必须从 GitHub 重新下载到新的临时目录，复核 SHA-256 并使用正式公钥做密码学验签。
- draft 资产验证通过后才能发布 prerelease；公开下载再次验证通过后，才允许部署 GitHub Pages 元数据。
- 若任一步失败，不更新稳定 `latest.json`，也不删除或改写旧版本伪造成功。

## 本地预检

`plan-github-release.ps1` 默认只返回预览。它读取禁用配置，检查 GitHub CLI 登录、公开 login 的脱敏值、至少 `WRITE` 权限、仓库身份和公开性、本地 `origin`、当前 HEAD 已存在于目标仓库、目标 tag/release/资产名尚未占用、干净工作区、版本、manifest、SHA-256、`.sig`、正式公钥指纹、`latest.json` 绑定关系及真实验签结果：

```powershell
.\scripts\updater\plan-github-release.ps1 `
  -Version '<目标版本>' `
  -CurrentVersion '<基础版本>' `
  -ArtifactPath '<版本化安装包>' `
  -SignaturePath '<版本化安装包>.sig' `
  -PublicKeyPath "$env:USERPROFILE\.tauri\qijiang-desktop-pet.key.pub" `
  -LatestJsonPath '<版本目录>\latest.json' `
  -ManifestPath '<版本目录>\updater-release-manifest.json' `
  -ChecksumPath '<版本目录>\SHA256SUMS.txt' `
  -WhatIf
```

配置保持禁用、GitHub Pages 尚未得到明确确认或任意预检项失败时，Gate 为 false，`-ConfirmPlan` 会明确拒绝。任何 GitHub 查询异常都按失败处理。即使全部通过，`-ConfirmPlan` 也只确认本地计划，不创建 Release、不上传资产、不推送分支、不更改 Pages。

## 上传后的回下载验证

远端资产由已授权的独立步骤创建后，可运行只读验证器：

```powershell
.\scripts\updater\verify-github-release-assets.ps1 `
  -Version '<目标版本>' `
  -CurrentVersion '<基础版本>' `
  -ArtifactPath '<本地版本化安装包>' `
  -SignaturePath '<本地版本化安装包>.sig' `
  -PublicKeyPath "$env:USERPROFILE\.tauri\qijiang-desktop-pet.key.pub" `
  -LatestJsonPath '<版本目录>\latest.json' `
  -ManifestPath '<版本目录>\updater-release-manifest.json' `
  -ChecksumPath '<版本目录>\SHA256SUMS.txt'
```

验证器只执行读取和临时下载，不修改远端资源；它会独立复核下载 manifest 的 schema、版本转换、Git commit、身份、文件名、size、SHA-256、endpoint、公钥指纹、`latest.json`、checksums 和真实签名，并确认 commit/tag/release/资产都属于目标仓库。结束时删除临时副本，清理失败只返回脱敏错误。

发布 prerelease 后，还必须在未登录的干净环境验证公开安装包 URL。验证命令使用已发布状态与匿名模式，不读取 GitHub CLI 登录凭据：

```powershell
.\scripts\updater\verify-github-release-assets.ps1 `
  -Version '<目标版本>' `
  -CurrentVersion '<基础版本>' `
  -ArtifactPath '<本地版本化安装包>' `
  -SignaturePath '<本地版本化安装包>.sig' `
  -PublicKeyPath '<仓库外公钥路径>' `
  -LatestJsonPath '<版本目录>\latest.json' `
  -ManifestPath '<版本目录>\updater-release-manifest.json' `
  -ChecksumPath '<版本目录>\SHA256SUMS.txt' `
  -ReleaseExpectation Present `
  -Anonymous
```

只有 Pages 方案另行确认并实现后，才验证并启用 Pages URL。本轮不执行该命令、不创建或修改远端 Release。

## 权限与日志

GitHub 凭据只由 GitHub CLI 的安全凭据机制或受控 CI secret 管理，不写入配置、命令参数、release manifest 或 QA 报告。Production 私钥始终位于仓库外。发布日志只记录仓库名、tag、相对文件名、大小、哈希、公钥指纹和 Gate 结果，不记录私钥路径或本机绝对路径。
