# Desk Pet Framework

一个离线优先、资源包驱动的 Windows 桌宠开发框架。技术栈为 Tauri 2、React、TypeScript、Rust 和 Vite。当前版本只实现桌宠运行内核，不包含 AI、账号、支付、提醒、云同步或其他业务模块。

## 已实现

- 透明无边框窗口、置顶、缩放、透明度和多显示器可见区域修正
- 单实例运行、系统托盘、临时隐藏、恢复位置和安全退出
- 点击、双击、悬停、拖动阈值、落地反馈和互动冷却
- 配置驱动的 PNG 序列帧播放器与状态机
- `idle`、`blink`、`walk`、`sleep`、`click`、`drag`、`land`、`happy`
- 支持资源包自定义动作名，例如 `walk_left`、`walk_right`、`hover`、`double_click`
- 动画 FPS、循环、返回状态、权重、优先级、不可中断和水平翻转
- 角色索引、资源预加载、详细校验、损坏资源回退到占位角色或 `idle`
- 角色级默认缩放、交互动作映射和归一化矩形点击区域
- 本地设置保存、开机启动、日志和开发者面板
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

安装程序输出位于 `src-tauri/target/release/bundle/nsis/`，文件名以 `-setup.exe` 结尾。

## 添加角色

1. 复制 `public/characters/_placeholder` 到 `public/characters/<角色ID>`。
2. 修改 `manifest.json`，确保目录名与 `id` 一致。
3. 替换 `animations/<动作名>/` 下的透明 PNG 序列帧。
4. 保持同一动作所有帧画布尺寸一致，文件名使用 `idle_0001.png` 格式。
5. 运行 `npm run validate:characters`。脚本会重建 `characters/index.json` 和每个角色的 `frames.json`。
6. 在程序中选择“重新加载角色资源”，无需重启应用。

正式角色制作前必须先确认角色类型、画风、比例、配色、服装或外壳和标志性特征。详见 [角色资源包制作说明](docs/CHARACTER_PACK.md)。

## 调试

右键桌宠选择“设置”可调整普通运行选项。开发者面板可以查看角色 ID、资源路径、状态、优先级、帧号、FPS、缓存、校验警告和最近日志，并可模拟资源或设置损坏。

开发者面板只在开发构建中启用。确需制作内部诊断版时，可显式设置 `VITE_ENABLE_DEVELOPER_TOOLS=true` 后重新构建；普通 release 构建不会显示入口，即使旧设置文件中保存过开启状态也不会渲染面板。

## 稳定接口

`0.1.x` 将角色包 `schemaVersion: 1` 视为稳定基础协议。新增角色或动作应只增加资源目录并重建索引，不应修改 React 或 Rust 业务逻辑。破坏兼容性的角色协议变更必须提升 `schemaVersion`，同时保留清晰的不兼容错误。

## 离线与数据

核心运行不发起任何网络请求。设置保存在 Tauri 应用数据目录的 `settings.json`；浏览器预览使用 `localStorage` 回退。角色资源随安装包本地分发。

开机启动由 Tauri 插件使用当前安装后的可执行文件路径注册；应用每次启动都会按保存的设置刷新注册信息。覆盖安装升级仍需按 Windows QA 清单验证。
