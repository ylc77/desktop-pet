# Windows 发布与安装验证

## 构建

```powershell
npm run check:windows-env
npm run typecheck
npm run test
npm run validate:characters
npm run build
cargo fmt --check --manifest-path src-tauri/Cargo.toml
cargo check --manifest-path src-tauri/Cargo.toml -j1
cargo test --release --manifest-path src-tauri/Cargo.toml -j1
npm run build:release
```

`build:release` 会先确认 Node、npm、Rustup、Rustc 和 Cargo 位于 PATH。项目不写死开发者用户名或 Cargo 绝对路径。
若可用物理内存低于 4 GiB且未手动设置 `CARGO_BUILD_JOBS`，脚本会将本次构建限制为单作业，避免大型 Tauri 依赖并行编译导致 Rustc 内存分配失败；它不会修改永久环境变量。
Rust 测试 profile 不生成调试符号并关闭增量编译，以降低 Windows 页面文件和 LLVM 链接峰值；这不会跳过测试、警告或优化 Release 产物。

## Updater 构建边界

普通 `npm run build:release` 不需要生产密钥或 endpoint，主配置保持 `bundle.createUpdaterArtifacts: false`。当前 `0.1.0` 的安全更新基础已经接入，但生产公钥和 HTTPS endpoint 未配置；应用显示 `NOT_CONFIGURED`，启动时不访问更新服务。

`src-tauri/tauri.updater.conf.json` 固定记录签名构建必须使用 `createUpdaterArtifacts: true` 的公开契约。实际签名工具在 `%TEMP%` 生成一次性配置叠加，写入经过验证的 HTTPS endpoint、公钥和 Windows `passive` 安装模式；完成后删除，不把正式 endpoint 或公钥伪造进普通配置。达到生成生产密钥、设置 endpoint、真实签名或上传步骤时必须先获得用户确认。

只做预览：

```powershell
.\scripts\updater\initialize-updater-key.ps1 -WhatIf
```

签名构建与发布目录预览仍需要提供版本、用户确认的 HTTPS 地址、仓库外密钥路径和现有产物等必填参数；完整可复制模板见 [Updater 发布流程](UPDATER_RELEASE_PROCESS.md)。密码不得作为明文命令行参数。确认执行后的 create、prepare 和签名 build 会复用仓库内离线 Minisign 验证器；`prepare -WhatIf` 只报告确认后需要验签，不会生成验证器产物。密钥、托管与 QA 分别见 [密钥管理](UPDATER_KEY_MANAGEMENT.md)、[托管要求](UPDATER_HOSTING.md) 和 [Updater QA](UPDATER_QA.md)。

## 本机烟测脚本

所有会安装、卸载或启动程序的脚本都支持 `-WhatIf`：

```powershell
.\scripts\windows\install-smoke-test.ps1 -InstallerPath <setup.exe> -WhatIf
.\scripts\windows\process-smoke-test.ps1 -ExecutablePath <exe> -WhatIf
.\scripts\windows\uninstall-smoke-test.ps1 -WhatIf
.\scripts\windows\check-autostart.ps1
.\scripts\windows\check-leftovers.ps1
```

脚本不会绕过 UAC。安装和卸载失败返回非零退出码。`process-smoke-test.ps1` 的正常退出阶段要求测试者通过托盘或右键菜单退出；只有显式传入 `-AllowForceCleanup` 时才会在超时后强制清理，而强制清理不能算正常退出通过。

这些脚本用于可重复记录本机状态，不能代替干净 Windows、真实升级路径或企业网络环境测试。

统一 QA 入口：

```powershell
.\scripts\windows\run-qa-suite.ps1 -Mode Safe
.\scripts\windows\run-qa-suite.ps1 -Mode CurrentMachine -WhatIf
.\scripts\windows\run-qa-suite.ps1 -Mode CleanEnvironment -WhatIf
```

Safe 模式只执行非破坏性构建、测试、哈希、签名状态、清单和 Git 检查。CurrentMachine 会先列出安装、启动、正常退出等待、开机启动检查和卸载动作，再由 PowerShell 确认机制决定是否执行。CleanEnvironment 不根据主机名判断安全性，必须在明确指定的可丢弃环境中设置 `DESK_PET_QA_CLEAN_ENVIRONMENT=1`。

## Release 可追溯信息

公开测试版总控与审核：

```powershell
.\scripts\windows\run-public-beta-qa.ps1 -Mode Safe
.\scripts\windows\run-public-beta-qa.ps1 -Mode PublicBetaAudit
```

环境结果独立保存在 `qa-results/public-beta/<environment-id>/environment-result.json`。审核脚本读取每个检查的实际状态和证据，不会因为文件存在就自动判定通过。只有 Gate 真正满足后才可准备 `release/public-beta`；当前不得仅改文件名或提前创建 `beta.1` 标签。

当前自动更新状态是 `INTEGRATED / NOT_CONFIGURED`。生产 updater 公钥或 endpoint 缺失、Updater 产物/元数据未生成，或两个真实版本升级未完成时，Public Beta Gate 必须报告 `BLOCKED`，不能因为普通构建通过而标记为 passed。

生产 updater Release 的验证必须显式提供仓库外公钥，并要求真实密码学验签：

```powershell
.\scripts\windows\verify-release-artifacts.ps1 `
  -ReleaseDirectory '.\release' `
  -RequireUpdater `
  -UpdaterPublicKeyPath '<仓库外公钥路径>'

.\scripts\windows\audit-public-beta-readiness.ps1 `
  -UpdaterPublicKeyPath '<仓库外公钥路径>'
```

Gate 同时绑定 `latest.json` 的精确版本、URL 文件名、`.sig` 文件名、实际 `size`、公钥指纹和安装包密码学签名；仅有 `.sig` 文件或指纹相等不能通过。Public Beta Audit 还要求真实环境证据，因此 updater 验签通过仍不代表可公开发布。

成功构建并完成测试后运行：

```powershell
.\scripts\create-release-manifest.ps1 -TestSummary @(
  'typecheck: passed',
  'frontend tests: passed',
  'character validation: passed',
  'cargo tests: passed',
  'NSIS build: passed'
)
```

脚本创建忽略版本控制的 `release/` 目录，保留版本化 NSIS 安装包，并额外生成内容相同的 `七酱桌宠.exe`。`SHA256SUMS.txt` 同时记录对外文件和版本化文件；`release-manifest.json` 记录两者文件名、大小、SHA-256、`desktop_pet.exe`、版本和 Git commit。脚本不会覆盖来源不明且哈希不同的同名对外文件。清单只记录相对产物文件名，不包含用户名或绝对路径；Git commit 不可用时为 `null`，绝不伪造。

Updater 使用版本化安装包及配对的 `.sig`，绝不使用 `七酱桌宠.exe` 可变别名作为下载 URL。采用 Windows Authenticode 后，只有完成 Windows 签名与时间戳的文件才是最终文件；随后必须重新计算 SHA-256、重新生成 Tauri Updater `.sig`、`latest.json`、校验和与 manifest。当前 Windows 代码签名仍为 `NotSigned`，详见 [Windows 代码签名待办](WINDOWS_CODE_SIGNING_TODO.md)。

## 已知 Rust 链接器提示

触发命令：`cargo test --manifest-path src-tauri/Cargo.toml` 和包含 `cdylib` 的 Release 构建。

完整原始输出保存在 `docs/build-logs/linker-warning.txt`。这是 MSVC `link.exe` 在为 `desk_pet_framework_lib.dll` 创建 import library (`.dll.lib`) 和 export (`.dll.exp`) 文件时写到标准输出的正常信息。Rust 1.97 的 `linker_messages` lint 将非空 linker stdout 包装为 warning。

生成的 `.dll.lib` 和 `.dll.exp` 是编译期产物，不由 NSIS 安装到目标电脑；应用 EXE 和安装包均正常生成。因此它不影响干净电脑启动、WebView2/DLL 加载、x64 目标或后续对 EXE/安装包进行代码签名。当前结论是不阻止发布，也不通过禁用 warning 掩盖它；若 MSVC 或 Rust 工具链升级后文本变化，应重新调查。

## 卸载和本地数据策略

NSIS 卸载负责程序目录、快捷方式和应用注册信息。用户设置和日志默认保留，便于重装和故障诊断。彻底清除必须由用户明确选择，并且只能在应用退出后删除：

- `%APPDATA%\dev.deskpet.framework`
- `%LOCALAPPDATA%\dev.deskpet.framework`

不得递归删除其父目录或任何其他应用数据。
