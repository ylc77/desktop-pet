# 系统要求

## 最终用户

- Windows 10 或 Windows 11 x64；当前未提供 ARM64 公开支持。
- Microsoft Edge WebView2 Evergreen Runtime。
- 缺失 WebView2 时需要网络连接供 `downloadBootstrapper` 下载；当前不支持完全离线 Runtime 内置安装。
- 建议至少 4 GiB 内存和可用的现代图形驱动。
- 不需要 Node.js、Rust、Visual Studio 或源码。

真实 Windows 10/11 干净系统、中文用户名、混合 DPI 和双显示器兼容性仍属于公开测试版 Gate，不能仅凭自动化结果宣称全部支持。

## 开发与构建

- Node.js 22 或更新版本及 npm；
- Rust stable MSVC 工具链；
- Visual Studio C++ Build Tools 和 Windows SDK；
- WebView2 Runtime；
- 用于 NSIS/Tauri Release 的 x64 Windows 开发环境。
