# Windows 发布与安装验证

## 构建

```powershell
npm run check:windows-env
npm run typecheck
npm run test
npm run validate:characters
npm run build
cargo fmt --check --manifest-path src-tauri/Cargo.toml
cargo check --manifest-path src-tauri/Cargo.toml
cargo test --manifest-path src-tauri/Cargo.toml
npm run build:release
```

`build:release` 会先确认 Node、npm、Rustup、Rustc 和 Cargo 位于 PATH。项目不写死开发者用户名或 Cargo 绝对路径。
若可用物理内存低于 4 GiB且未手动设置 `CARGO_BUILD_JOBS`，脚本会将本次构建限制为单作业，避免大型 Tauri 依赖并行编译导致 Rustc 内存分配失败；它不会修改永久环境变量。
Rust 测试 profile 不生成调试符号并关闭增量编译，以降低 Windows 页面文件和 LLVM 链接峰值；这不会跳过测试、警告或优化 Release 产物。

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

脚本创建忽略版本控制的 `release/` 目录，复制 NSIS 安装包并生成 `SHA256SUMS.txt` 和 `release-manifest.json`。清单只记录相对产物文件名，不包含用户名或绝对路径；Git commit 不可用时为 `null`，绝不伪造。

## 已知 Rust 链接器提示

触发命令：`cargo test --manifest-path src-tauri/Cargo.toml` 和包含 `cdylib` 的 Release 构建。

完整原始输出保存在 `docs/build-logs/linker-warning.txt`。这是 MSVC `link.exe` 在为 `desk_pet_framework_lib.dll` 创建 import library (`.dll.lib`) 和 export (`.dll.exp`) 文件时写到标准输出的正常信息。Rust 1.97 的 `linker_messages` lint 将非空 linker stdout 包装为 warning。

生成的 `.dll.lib` 和 `.dll.exp` 是编译期产物，不由 NSIS 安装到目标电脑；应用 EXE 和安装包均正常生成。因此它不影响干净电脑启动、WebView2/DLL 加载、x64 目标或后续对 EXE/安装包进行代码签名。当前结论是不阻止发布，也不通过禁用 warning 掩盖它；若 MSVC 或 Rust 工具链升级后文本变化，应重新调查。

## 卸载和本地数据策略

NSIS 卸载负责程序目录、快捷方式和应用注册信息。用户设置和日志默认保留，便于重装和故障诊断。彻底清除必须由用户明确选择，并且只能在应用退出后删除：

- `%APPDATA%\dev.deskpet.framework`
- `%LOCALAPPDATA%\dev.deskpet.framework`

不得递归删除其父目录或任何其他应用数据。
