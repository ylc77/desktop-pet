# 七酱桌宠

七酱桌宠是一个离线优先、资源包驱动的 Windows 桌宠应用，底层保留可扩展的通用桌宠框架。技术栈为 Tauri 2、React、TypeScript、Rust 和 Vite。当前版本不包含 AI、账号、支付、提醒、云同步、遥测或广告；生产 updater 公钥与 GitHub Releases beta endpoint 已确认，签名候选与真实 A → B 验证仍在发布 Gate 内。

## 已实现

- 透明无边框窗口、置顶、缩放、透明度和多显示器可见区域修正
- 单实例运行、系统托盘、临时隐藏、恢复位置和安全退出
- 点击、双击、悬停、拖动阈值、落地反馈和互动冷却
- 配置驱动的 PNG 序列帧播放器与状态机
- `idle`、`blink`、`walk`、`sleep`、`click`、`drag`、`land`、`happy`
- 支持资源包自定义动作名，例如 `walk_left`、`walk_right`、`hover`、`double_click`
- 动画 FPS、循环、返回状态、权重、优先级、不可中断和水平翻转
- 角色索引、资源预加载、详细校验、损坏资源回退到占位角色或 `idle`
- 外观中心统一展示内置角色和本地导入角色，可切换、导入、升级或安全删除本地角色包；删除当前角色前会先回退到有效内置角色
- 角色级默认缩放、交互动作映射和归一化矩形点击区域
- 本地设置保存、开机启动、日志和开发者面板
- 带白猫应用图标的关于页面、固定延迟 15 秒的启动自动检查、手动检查、自动检查开关、脱敏诊断导出和二次确认的默认设置恢复
- Tauri 2 Updater/Process 安全更新基础；未配置构建保持离线且不下载安装，生产发布工具要求真实密码学验签
- NSIS Windows 安装包配置

当前素材是带 `DEV` 标识的中性几何占位图，不是正式桌宠外观。

## 环境要求

- Windows 10 或 Windows 11
- Node.js 22 或更新版本
- Rust stable（通过 rustup 安装）
- Microsoft WebView2 与 Visual Studio C++ Build Tools（Windows 10 通常需要确认）

最终用户安装 NSIS 安装包后不需要 Node.js 或 Rust。

## 开发

```powershell
npm install
npm run generate:placeholder
npm run validate:characters
npm run tauri:dev
```

只运行浏览器界面预览：

```powershell
npm run dev
```

浏览器预览无法验证原生拖动、托盘、单实例和开机启动。

## 验证与构建

```powershell
npm run typecheck
npm run test
npm run validate:characters
npm run build
cargo check --manifest-path src-tauri/Cargo.toml
npm run build:release
```

版本化安装程序输出位于 `src-tauri/target/release/bundle/nsis/`，文件名以 `-setup.exe` 结尾；`release/七酱桌宠.exe` 是内容完全相同的对外文件。主程序文件名为 `desktop_pet.exe`。

## 添加角色

角色不限定人物、动物、真人、宠物、游戏角色或画风；每个角色都以独立资源包接入，核心代码不保存角色名称、外观和固定帧数。公开随应用分发的内置角色与用户仅在本机使用的本地角色必须区分授权范围。

制作内置角色：

1. 复制 `public/characters/_placeholder` 到 `public/characters/<角色ID>`。
2. 修改 `manifest.json`，确保目录名与 `id` 一致。
3. 替换 `animations/<动作名>/` 下的透明 PNG 序列帧。
4. 保持同一动作所有帧画布尺寸一致，文件名使用 `idle_0001.png` 格式。
5. 运行 `npm run validate:characters`。脚本会重建 `characters/index.json` 和每个角色的 `frames.json`。
6. 在程序中选择“重新加载角色资源”，无需重启应用。

制作可导入的单文件包：

```powershell
npm run package:character -- -CharacterId <角色ID>
```

脚本先执行完整角色校验并确认 `frames.json`，再把角色目录内容直接压缩为 ZIP 兼容的 `character-packages/<角色ID>_<版本>.qipet`；包根是 `manifest.json`，不包含外层角色目录。已存在的同名包不会被覆盖，完成后会输出文件大小和 SHA-256。用户通过“外观中心 → 导入角色包”安装，应用将安全校验后的内容写入 `%LOCALAPPDATA%\dev.deskpet.framework\characters\<角色ID>`。该目录由稳定 identifier 派生，不随产品显示名称变化；卸载默认保留本地角色数据。

公开内置角色必须提供 `metadata/source.md` 和 `metadata/license.md`，并确认发布、改编、商业使用与再分发权。私人导入只保存在本机，不代表应用授予原角色、商标、照片或肖像的使用权，也不应被自动纳入安装包或公开索引。不同服装或完整造型的首版交付按独立角色包和独立 ID 管理，避免未成熟的图层组合破坏动作一致性。

每次制作角色时由 Codex 根据角色画风、目标显示尺寸、动作目的和复杂度单独制定帧数、FPS、循环和前摇/收尾；项目不设一套全局固定帧数。接入格式见 [角色资源包制作说明](docs/CHARACTER_PACK.md)，制作前先填写 [角色制作规格模板](docs/CHARACTER_PRODUCTION_PROFILE_TEMPLATE.md)，正式素材的制作与版权要求见 [高保真角色素材制作规范](docs/HIGH_FIDELITY_CHARACTER_ASSET_GUIDE.md)，人工审核使用 [角色视觉人工验收清单](docs/CHARACTER_VISUAL_REVIEW_CHECKLIST.md)。当前正式路径仍是 `schemaVersion: 1` 的 PNG 序列帧；技术校验通过不等于正式美术通过。

## 调试

右键桌宠选择“设置”可调整普通运行选项。开发者面板可以查看角色 ID、资源路径、状态、优先级、帧号、FPS、缓存、校验警告和最近日志，并可模拟资源或设置损坏。

开发者面板只在开发构建中启用。确需制作内部诊断版时，可显式设置 `VITE_ENABLE_DEVELOPER_TOOLS=true` 后重新构建；普通 release 构建不会显示入口，即使旧设置文件中保存过开启状态也不会渲染面板。

## 稳定接口

`0.1.x` 将角色包 `schemaVersion: 1` 视为稳定基础协议。新增角色或动作应只增加资源目录并重建索引，不应修改 React 或 Rust 业务逻辑。破坏兼容性的角色协议变更必须提升 `schemaVersion`，同时保留清晰的不兼容错误。

## 离线与数据

普通未配置构建不会发起更新请求。以后只有配置正式 HTTPS 更新源且自动检查开启，或用户主动手动检查时，应用才会访问更新服务；检查请求不附带账号、设置、日志、角色资源或诊断包。设置保存在 Tauri 应用数据目录的 `settings.json`；浏览器预览使用 `localStorage` 回退。内置角色随安装包分发，本地角色只从用户主动选择的 `.qipet` 导入，不上传到在线服务。

诊断信息只能由用户主动导出到本地，不会自动上传。自动更新默认不静默下载或安装，用户可以关闭启动自动检查。详见 [自动更新说明](docs/AUTO_UPDATE.md)、[隐私说明](docs/PRIVACY.md) 与 [关于和诊断](docs/ABOUT_AND_DIAGNOSTICS.md)。

用户单击一次“立即更新”后，应用才依次下载、验证、严格保存设置与窗口状态并交给 passive NSIS 安装；原生写入失败会阻止安装。正常路径由 Tauri Updater 清理并退出旧进程，NSIS 完成后自动启动新版本；Process relaunch 只在安装命令异常返回时兜底，兜底重启失败后的重试不会再次安装。新进程仅在实际版本与待确认目标一致时清除 pending；否则持久化失败目标并只提示一次。生产元数据生成、发布准备、签名构建和 Gate 都要求用外部公钥真实验证安装包与 `.sig`，并绑定版本化文件名和实际字节数；这仍不能替代尚未完成的真实 A → B QA。

开机启动由 Tauri 插件使用当前安装后的可执行文件路径注册；应用每次启动都会按保存的设置刷新注册信息。覆盖安装升级仍需按 Windows QA 清单验证。

## Windows 开发环境准备

开发和打包机需要安装：

- Node.js 22 或更高版本，以及 npm。
- Rustup、stable MSVC Rust toolchain（`x86_64-pc-windows-msvc`）。
- Visual Studio Build Tools，勾选“使用 C++ 的桌面开发”。
- Windows 10/11 SDK。
- Microsoft Edge WebView2 Runtime。

Rustup 默认把 Cargo 安装到 `%USERPROFILE%\.cargo\bin`。该目录必须位于用户 `PATH` 中；修改 PATH 后应关闭旧终端并打开新终端。项目脚本不依赖某个用户名的绝对 Cargo 路径。

只读环境诊断：

```powershell
npm run check:windows-env
npm run qa:safe
```

诊断脚本检查 Node、npm、Rust、Cargo、Rustup、MSVC、Windows SDK、WebView2、系统架构和必要环境变量，不会修改系统 PATH、注册表或安装组件。`npm run build:release` 会在构建开始前检查这些命令；Cargo 缺失时立即给出明确错误。

## WebView2 安装策略

NSIS 明确使用 Tauri 的 `downloadBootstrapper` 模式并静默运行 WebView2 bootstrapper。目标电脑已有 Evergreen WebView2 Runtime 时不会重复安装；缺失时安装过程需要联网下载 Runtime。离线且未预装 WebView2 的电脑不能依靠当前小体积安装包完成安装，应先由管理员部署官方 Evergreen Offline Installer，再运行桌宠安装包。

WebView2 下载或安装失败必须视为安装失败，不能把“程序文件已复制但应用不能启动”标记为成功。干净 Windows 10/11、断网、代理和受限企业网络场景仍需按照 `docs/WINDOWS_QA.md` 人工验证。当前没有把约 127 MiB 的完整离线 Runtime 打入安装包。

## 本地数据和日志

- 设置：`%APPDATA%\dev.deskpet.framework\settings.json`。
- 设置备份：同目录下的 `settings.backup.json`；损坏文件会重命名为 `settings.corrupt-<时间戳>.json`。
- 日志：`%LOCALAPPDATA%\dev.deskpet.framework\logs\`，单文件上限 1 MiB，最多保留 5 个轮转文件。
- 内置角色资源：随应用前端资源一起打包，不从在线服务下载。
- 本地角色资源：由用户从外观中心导入，保存在 `%LOCALAPPDATA%\dev.deskpet.framework\characters\`，卸载默认保留。
- 缓存：应用没有自定义持久图片缓存；WebView2 自身缓存由 Runtime 管理。
- 崩溃信息：项目不上传崩溃报告；可使用本地日志和 Windows Error Reporting 进行诊断。

设置写入使用同目录临时文件、刷新磁盘后原子替换，并在覆盖前保存上一版本。单实例锁和原生写入互斥锁防止两个进程同时写设置。NSIS 卸载默认不擅自删除用户设置；需要彻底清除时，应先退出应用，再仅删除上述两个 `dev.deskpet.framework` 应用数据目录。

## 发布工程

发布流程、QA 总控、安装烟测、已知链接器提示和发布清单格式见 [docs/RELEASE.md](docs/RELEASE.md)。Updater 的密钥、托管、发布与 QA 分别见 [密钥管理](docs/UPDATER_KEY_MANAGEMENT.md)、[托管要求](docs/UPDATER_HOSTING.md)、[更新发布流程](docs/UPDATER_RELEASE_PROCESS.md) 和 [Updater QA](docs/UPDATER_QA.md)。长期资源监控流程见 [docs/PERFORMANCE_TEST.md](docs/PERFORMANCE_TEST.md)。真实显示器、Sandbox/VM、WebView2 及签名检查均有独立 QA 文档。`CurrentMachine` 和 `CleanEnvironment` 模式会在任何安装或卸载前列出影响并使用 PowerShell 确认机制。

公开测试版准备状态、已知阻碍和统一 Gate 见 [公开测试版验收清单](docs/PUBLIC_BETA_CHECKLIST.md) 与 [已知问题](docs/KNOWN_ISSUES.md)。当前仍是内部测试基线，不是已发布的公开 beta；生产 updater 密钥/endpoint、两个真实版本升级、Windows 代码签名决策、干净 Windows、卸载、多显示器和稳定性 Gate 完成前，不得宣称自动更新或公开测试版可公开使用。

## 许可与资源权利

七酱桌宠源码与项目自有资源采用专有许可，不允许未经授权复制、修改或再分发。测试用户对官方已编译程序的有限安装与评估权利见根目录 [LICENSE](LICENSE)。第三方组件继续适用其各自许可证，清单见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。白猫应用图标与中性占位素材的公开测试分发边界见 [docs/ASSET_RIGHTS.md](docs/ASSET_RIGHTS.md)。
