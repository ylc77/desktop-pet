# 七酱桌宠第三方组件声明

本文件适用于版本 `0.1.2-beta.3` 的构建基线。七酱桌宠自身为专有软件；下列第三方组件继续适用其各自许可证。本声明不改变、限制或替代任何第三方许可证原文。

版本以本仓库的 `package-lock.json` 和 `src-tauri/Cargo.lock` 为准。升级依赖时必须同步更新本文件并重新执行许可证审查。

## 前端运行时组件

| 组件 | 锁定版本 | 声明许可证 | 上游 |
|---|---:|---|---|
| `@tauri-apps/api` | 2.11.1 | Apache-2.0 OR MIT | https://github.com/tauri-apps/tauri |
| `@tauri-apps/plugin-autostart` | 2.5.1 | MIT OR Apache-2.0 | https://github.com/tauri-apps/plugins-workspace |
| `@tauri-apps/plugin-log` | 2.9.0 | MIT OR Apache-2.0 | https://github.com/tauri-apps/plugins-workspace |
| `@tauri-apps/plugin-process` | 2.3.1 | MIT OR Apache-2.0 | https://github.com/tauri-apps/plugins-workspace |
| `@tauri-apps/plugin-updater` | 2.10.1 | MIT OR Apache-2.0 | https://github.com/tauri-apps/plugins-workspace |
| `react` | 19.2.7 | MIT | https://github.com/facebook/react |
| `react-dom` | 19.2.7 | MIT | https://github.com/facebook/react |
| `scheduler` | 0.27.0 | MIT | https://github.com/facebook/react |
| `zod` | 4.4.3 | MIT | https://github.com/colinhacks/zod |

## Rust 直接依赖

| 组件 | 锁定版本 | 声明许可证 | 上游 |
|---|---:|---|---|
| `log` | 0.4.33 | MIT OR Apache-2.0 | https://github.com/rust-lang/log |
| `png` | 0.18.1 | MIT OR Apache-2.0 | https://github.com/image-rs/image-png |
| `semver` | 1.0.28 | MIT OR Apache-2.0 | https://github.com/dtolnay/semver |
| `serde` | 1.0.228 | MIT OR Apache-2.0 | https://github.com/serde-rs/serde |
| `serde_json` | 1.0.150 | MIT OR Apache-2.0 | https://github.com/serde-rs/json |
| `sha2` | 0.10.9 | MIT OR Apache-2.0 | https://github.com/RustCrypto/hashes |
| `tauri` | 2.11.5 | Apache-2.0 OR MIT | https://github.com/tauri-apps/tauri |
| `tauri-build` | 2.6.3 | Apache-2.0 OR MIT | https://github.com/tauri-apps/tauri |
| `tauri-plugin-autostart` | 2.5.1 | Apache-2.0 OR MIT | https://github.com/tauri-apps/plugins-workspace |
| `tauri-plugin-dialog` | 2.7.1 | Apache-2.0 OR MIT | https://github.com/tauri-apps/plugins-workspace |
| `tauri-plugin-log` | 2.9.0 | Apache-2.0 OR MIT | https://github.com/tauri-apps/plugins-workspace |
| `tauri-plugin-process` | 2.3.1 | Apache-2.0 OR MIT | https://github.com/tauri-apps/plugins-workspace |
| `tauri-plugin-single-instance` | 2.4.3 | Apache-2.0 OR MIT | https://github.com/tauri-apps/plugins-workspace |
| `tauri-plugin-updater` | 2.10.1 | Apache-2.0 OR MIT | https://github.com/tauri-apps/plugins-workspace |
| `url` | 2.5.8 | MIT OR Apache-2.0 | https://github.com/servo/rust-url |
| `windows-sys` | 0.61.2 | MIT OR Apache-2.0 | https://github.com/microsoft/windows-rs |
| `zip` | 8.6.0 | MIT | https://github.com/zip-rs/zip2 |

上述依赖还会引入锁文件记录的传递依赖；各传递依赖的包分发内容中包含对应许可证和版权声明。发布审查必须以锁文件解析结果检查所有传递依赖，不得仅依赖本表。

## 外部运行时与构建工具

- Windows WebView2 Runtime 由 Microsoft 提供并适用 Microsoft WebView2 Runtime 条款。当前安装器使用 Tauri `downloadBootstrapper` 策略按需下载，不把完整 Runtime 二进制直接纳入本仓库。
- NSIS 用于生成 Windows 安装程序，适用其上游许可证；它属于构建工具，不代表七酱桌宠源码采用相同许可证。
- Windows 系统 API、图标缓存、安装注册表和系统托盘由 Windows 提供并受 Microsoft 条款约束。
- 界面只使用 Windows 提供的 `Segoe UI Variable Text`、`Microsoft YaHei UI`、`Segoe UI` 及浏览器系统字体回退；安装包不捆绑另行授权的字体文件。

## MPL-2.0 组件来源与修改状态

以下五个组件均为 `Cargo.lock` 精确锁定的 crates.io 原始发布包，`modified=false`。本项目没有对它们使用 Cargo `[patch]`、`[replace]`、source replacement 或 vendor override。

| 组件 | 精确版本 | Cargo.lock SHA-256 checksum | crates.io 精确来源 | modified |
|---|---:|---|---|---|
| `cssparser` | 0.36.0 | `dae61cf9c0abb83bd659dab65b7e4e38d8236824c85f0f804f173567bda257d2` | https://crates.io/api/v1/crates/cssparser/0.36.0/download | false |
| `cssparser-macros` | 0.6.1 | `13b588ba4ac1a99f7f2964d24b3d896ddc6bf847ee3855dbd4366f058cfcd331` | https://crates.io/api/v1/crates/cssparser-macros/0.6.1/download | false |
| `dtoa-short` | 0.3.5 | `cd1511a7b6a56299bd043a9c167a6d2bfb37bf84a6dfceaba651168adfb43c87` | https://crates.io/api/v1/crates/dtoa-short/0.3.5/download | false |
| `option-ext` | 0.2.0 | `04744f49eae99ab78e0d5c0b603ab218f515ea8cfe5a456d7629ad883a3b6e7d` | https://crates.io/api/v1/crates/option-ext/0.2.0/download | false |
| `selectors` | 0.36.1 | `c5d9c0c92a92d33f08817311cf3f2c29a3538a8240e94a6a3c622ce652d7e00c` | https://crates.io/api/v1/crates/selectors/0.36.1/download | false |

## 随安装包分发的许可原文

安装包同时携带 `THIRD_PARTY_LICENSES.txt`。该文件由 `package-lock.json`、`src-tauri/Cargo.lock` 和已锁定包中的 `LICENSE`、`LICENCE`、`COPYING`、`NOTICE`、`COPYRIGHT`、`LICENSE.spdx` 内容确定性生成；每个生产 npm 包和 sourced Cargo crate 恰好有一条记录。相同正文以 SHA-256 内容地址去重，包内缺失的许可原文由仓库内固定的 SPDX License List 3.28.0 全文缓存补足。

`npm run generate:licenses` 只使用本机已经安装/缓存的锁定依赖，不访问网络；`npm run validate:licenses` 也完全离线，并会在锁文件变化、记录遗漏或重复、聚合文件过期、正文损坏、出现本机绝对路径、未知许可表达式，或聚合文件没有加入 Tauri `bundle.resources` 时阻止构建。SPDX 缓存只可通过单独的维护审查升级，普通构建不得下载许可文本。

## 许可证原文

完整许可原文随安装包中的 `THIRD_PARTY_LICENSES.txt` 提供，也可从上述上游仓库、对应 npm 包或 Cargo crate 的发布内容中取得。公开构建归档必须同时保留本声明和完整聚合文件；依赖或锁文件变化后必须重新生成、执行离线验证并完成人工复核。发现未知许可证表达式、正文缺失、来源冲突或额外分发义务时，应阻止发布。
