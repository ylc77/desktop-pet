# Updater 托管：GitHub Releases beta 渠道

项目所有者已确认使用公开仓库 `ylc77/desktop-pet` 托管生产 Updater。仓库已通过匿名 HTTP 检查，应用不内置 GitHub Token。稳定元数据 endpoint 为：

```text
https://github.com/ylc77/desktop-pet/releases/latest/download/latest.json
```

正式契约位于 `config/updater.github-releases.json`，当前为 `enabled: true`、`metadata.ownerConfirmed: true`。配置仅包含公开托管信息，不包含私钥、密码或访问凭据。远端 Release 尚未创建；本地配置完成不等于 endpoint 已经可下载。

## GitHub latest 约束

版本仍采用预发布 SemVer，例如 `0.1.2-beta.1`，但承载稳定 endpoint 的 GitHub Release 必须满足：

- 先创建为 draft，上传并验证全部资产。
- 发布时设为 GitHub latest。
- GitHub `prerelease` 标志必须为 `false`，否则 `/releases/latest/` 不能作为可靠 beta 指针。
- Release 名称和 tag 仍明确包含 `beta`，不得把它描述为稳定正式版。

安装包下载 URL 永远固定到版本 tag，不使用 `七酱桌宠.exe` 或其他可覆盖别名：

```text
Release tag: v0.1.2-beta.1
Artifact: 七酱桌宠_0.1.2-beta.1_x64-setup.exe
Signature: 七酱桌宠_0.1.2-beta.1_x64-setup.exe.sig
Download: https://github.com/ylc77/desktop-pet/releases/download/v0.1.2-beta.1/<版本化安装包>
Metadata snapshot: https://github.com/ylc77/desktop-pet/releases/download/v0.1.2-beta.1/latest.json
Stable endpoint: https://github.com/ylc77/desktop-pet/releases/latest/download/latest.json
```

## 托管契约

- 仓库必须保持 `PUBLIC`，并允许未登录用户下载 Release 资产。
- 全部 URL 使用 HTTPS，不含凭据、query 或 fragment。
- tag、安装包文件名和 `.sig` 文件名包含完整 SemVer。
- 版本化资产不可覆盖；发现同名 tag、Release 或资产时安全失败。
- `latest.json` 使用 UTF-8 无 BOM，平台键为 `windows-x86_64`，安装模式为 `passive`。
- `latest.json` 的 URL、signature 和 size 必须分别等于版本化安装包 URL、`.sig` 正文和实际字节数。
- draft 上传完成后必须重新下载全部资产，核对 SHA-256 并用生产公钥真实验签。
- 远端验证通过后才允许发布并设为 latest；随后再做匿名回下载验证。
- 任一步失败都不得发布、替换资产或伪造通过结果。

## 本地预检

`plan-github-release.ps1` 默认只做预览。它检查 GitHub 登录、公开仓库身份、写权限、本地 origin、当前 HEAD、目标 tag/Release/资产冲突、干净工作区、版本、manifest、SHA-256、`.sig`、公钥指纹、`latest.json` 绑定关系和真实验签：

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

即使 `GateSatisfied=true`，该脚本也不会创建 Release、上传资产、推送 Git 或修改远端。所有远端写入仍需要单独授权。

## 上传后的只读验证

上传 draft 后运行认证回下载；正式发布并设为 latest 后，再运行匿名验证：

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

验证器只读取 GitHub 并下载到唯一临时目录，不修改远端。GitHub 凭据只由 GitHub CLI 或受控 CI secret 管理；生产私钥始终位于仓库外，日志不得记录密码、私钥或本机绝对路径。
