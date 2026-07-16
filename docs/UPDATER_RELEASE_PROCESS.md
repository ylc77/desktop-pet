# Updater 发布流程

本文描述已集成但尚未投入公开使用的更新发布基础。当前应用版本为 `0.1.0`，生产 updater 密钥和 endpoint 未配置，Windows Authenticode 为 `NotSigned`，所以只能执行普通构建、脚本预览和不触发安装的测试。

## 两类构建

普通 Release 构建不要求 updater 秘密，`src-tauri/tauri.conf.json` 保持 `bundle.createUpdaterArtifacts: false`，未配置时应用显示“更新服务尚未配置”且不联网：

```powershell
npm run build:release
```

`src-tauri/tauri.updater.conf.json` 记录签名构建的 `createUpdaterArtifacts: true` 契约。`build-signed-update.ps1` 实际在 `%TEMP%` 生成一次性 Tauri 配置叠加，加入经验证的 HTTPS endpoint、公钥与 `passive` 安装模式，并在 `finally` 删除。运行时 Rust 封装通过本次构建进程的 `QIJIANG_UPDATER_ENDPOINT` 和 `QIJIANG_UPDATER_PUBLIC_KEY` 固化同一组公开配置；缺任意一项即保持 `NOT_CONFIGURED`。签名构建只能在生产密钥和 endpoint 经用户确认后运行。

预览签名构建，不生成密钥、不签名、不上传：

```powershell
.\scripts\updater\build-signed-update.ps1 `
  -Version '<目标版本>' `
  -EndpointBaseUrl 'https://<用户确认的域名>/<路径>/' `
  -PrivateKeyPath '<仓库外私钥路径>' `
  -PublicKeyPath '<仓库外公钥路径>' `
  -OutputDirectory '.\release\updater-build\<目标版本>' `
  -Channel beta `
  -WhatIf
```

实际参数以脚本帮助为准。省略 `-PublicKeyPath` 时，签名构建只会尝试私钥旁的 `<私钥>.pub`；正式发布建议始终显式传入。密码只能安全交互输入或存在于当前进程环境变量，不得写在命令行中。确认执行后的签名构建会用仓库内的离线验证器对最终安装包、`.sig` 和该公钥做真实 Minisign 验签，验证失败不会生成发布目录。

## 发布前检查

1. 工作区为预期 commit，无未审查更改；版本来自 Tauri 配置并与 `package.json`、`Cargo.toml`、`Cargo.lock` 一致。
2. identifier 保持 `dev.deskpet.framework`，角色协议保持 `schemaVersion: 1`。
3. 正式私钥位于仓库外，非空密码与至少两份离线备份已确认。
4. 正式公钥和 HTTPS endpoint 已由项目所有者确认，未使用示例值或本地地址。
5. Production updater 配置、capability、`passive` 安装模式与秘密扫描全部通过。
6. 当前版本 Gate 和已知问题已更新；没有把历史 QA 当成候选 commit 的结果。

## 生成与验证元数据

签名后的版本化安装包必须配有 `.sig`。准备发布目录前必须已经有最终版本化安装包、配对 `.sig` 和公钥文件。先做不写文件的预览：

```powershell
.\scripts\updater\prepare-updater-release.ps1 `
  -Version '<目标版本>' `
  -CurrentVersion '<基础版本>' `
  -ArtifactPath '.\release\updater-build\<目标版本>\<版本化安装包>.exe' `
  -SignaturePath '.\release\updater-build\<目标版本>\<版本化安装包>.exe.sig' `
  -PublicKeyPath '<仓库外公钥路径>' `
  -DownloadUrl 'https://<用户确认的域名>/<版本化安装包>.exe' `
  -Endpoint 'https://<用户确认的域名>/latest.json' `
  -Identifier 'dev.deskpet.framework' `
  -ReleaseDirectory '.\release' `
  -WhatIf
```

生成 `latest.json` 后立即验证：

```powershell
.\scripts\updater\create-latest-json.ps1 `
  -Version '<目标版本>' `
  -CurrentVersion '<基础版本>' `
  -ArtifactPath '<版本化安装包路径>' `
  -SignaturePath '<配对 .sig 路径>' `
  -PublicKeyPath '<仓库外公钥路径>' `
  -DownloadUrl 'https://<用户确认的域名>/<版本化安装包>.exe' `
  -OutputPath '<新的 latest.json 路径>' `
  -Notes '<发布说明>'

.\scripts\updater\validate-latest-json.ps1 `
  -LatestJsonPath '<latest.json 路径>' `
  -CurrentVersion '<基础版本>' `
  -ExpectedVersion '<目标版本>' `
  -ArtifactPath '<版本化安装包路径>' `
  -SignaturePath '<配对 .sig 路径>' `
  -PublicKeyPath '<仓库外公钥路径>'
```

`validate-latest-json.ps1` 的三件套参数 `-ArtifactPath`、`-SignaturePath`、`-PublicKeyPath` 必须同时提供或同时省略。省略时只做元数据结构检查，`CryptographicSignatureVerified` 明确为 `false`；生产验证必须提供三件套。

生产验证必须确认：有效 SemVer、新版本严格更高、安装包文件名包含精确目标版本、下载 URL 的末段与安装包文件名完全相同、`.sig` 文件名为 `<安装包文件名>.sig`、`signature` 等于 `.sig` 正文、`platforms.<target>.size` 等于安装包实际字节数、JSON 为 UTF-8 无 BOM且可重新解析，并由指定公钥对指定安装包做真实密码学验签。错误公钥、篡改安装包、元数据签名不一致、URL 别名或大小不一致都会失败。

`prepare-updater-release.ps1 -WhatIf` 只展示计划，不编译或写入离线验证器，因此会明确报告“确认后必须验签”；它不应被记录为密码学验证通过。确认执行后的 `prepare`、签名 `build`、独立 `create` 以及生产 Gate 都会复用同一离线验证器。发布目录准备完成后运行：

```powershell
.\scripts\windows\verify-release-artifacts.ps1 `
  -ReleaseDirectory '.\release' `
  -RequireUpdater `
  -UpdaterPublicKeyPath '<仓库外公钥路径>'

.\scripts\windows\audit-public-beta-readiness.ps1 `
  -UpdaterPublicKeyPath '<仓库外公钥路径>'
```

生产 Gate 不接受只有公钥指纹、`.sig` 文件存在或字符串相等的结果；必须返回真实验签成功。Public Beta Audit 仍会继续检查环境证据，所以密码学验证通过不等于整个 Gate 通过。

Release manifest 记录版本、相对产物名、文件大小、SHA-256、Git commit、工作区状态、updater 公钥指纹和更新产物。不得记录私钥、密码、令牌或私钥路径。

## Windows 代码签名顺序

如果以后采用 Windows Authenticode，只有完成代码签名和可信时间戳后的二进制才是最终发布文件。因为 Authenticode 会改变文件字节，必须在它之后：

1. 重新计算 SHA-256。
2. 使用 Tauri Updater 私钥为最终文件重新生成 `.sig`。
3. 重新生成 `latest.json`、`SHA256SUMS.txt` 和 release manifest。
4. 重跑 updater 签名验证、Windows 签名验证及全部 Release QA。

详见 [Windows 代码签名待办](WINDOWS_CODE_SIGNING_TODO.md)。

## 两版本真实升级

版本 A 和 B 必须是两个不可覆盖的真实构建，B 的 SemVer 严格高于 A，并使用同一 updater 公钥/私钥信任链。推荐的后续测试版本是 `0.2.0-beta.1` → `0.2.1-beta.1`，但本轮没有采用、构建或发布它们。

真实流程包括安装 A、修改设置、导入测试角色、托管 B、从 A 检查/下载/安装/重启、核对 B 版本与数据保留、确认单实例/启动项/安装记录，最后卸载 B 并检查残留。以下动作必须再次获得用户确认：生成生产密钥、设置正式 endpoint、上传文件、真实安装 A、自动升级到 B、重启应用或 Windows。

Windows 的正常更新路径是终止式交接：安装前先严格写入设置与 `pendingUpdateVersion`，写入失败立即阻止安装；Tauri Updater 启动 `passive` NSIS 后触发 `on_before_exit`，刷新日志并执行应用清理，然后退出旧进程。NSIS 完成替换后自动启动新程序；新进程以实际应用版本确认 `pendingUpdateVersion` 并只清理一次待确认状态。前端 Process relaunch 只是在安装命令意外返回时的受控后备，不应把旧进程继续运行或一次普通 JS relaunch 当作 Windows 主路径。

## Gate

只有签名产物、托管元数据、两版本端到端升级、失败场景、干净 Windows 10/11、SmartScreen/代码签名决策和生命周期 QA 都有可审计结果后，才可以把自动更新标记为 `END_TO_END_UPDATE_PASSED` 或 `PUBLIC_BETA_READY`。当前 Gate 必须保持 `BLOCKED`。
