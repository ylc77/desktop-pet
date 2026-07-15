# WebView2 安装 QA

当前包配置为 `downloadBootstrapper` 且静默安装。主机已安装 WebView2；不得卸载主机运行时来模拟缺失。

必须在可丢弃环境分别验证：

| 场景 | 操作 | 预期结果 | 结果 |
|---|---|---|---|
| 已安装 WebView2 | 正常安装并启动 | 不重复安装，桌宠启动 | 待填写 |
| 未安装且联网 | 安装 NSIS | bootstrapper 下载并安装运行时，随后应用可启动 | 待填写 |
| 未安装且断网 | 断网后安装 | 给出明确失败，不留下可启动性错误的半安装状态 | 待填写 |

断网失败后检查卸载注册项、安装目录、运行进程、开始菜单项和临时文件；网络恢复后重新安装应成功。若需要完全离线部署，应另行评估嵌入离线 WebView2 Runtime，本轮不改变打包策略。

## 公开测试版结论

当前公开测试版候选**不支持缺失 WebView2 时的完全离线安装**。配置仍为 `downloadBootstrapper`：目标机已有 Runtime 时可离线使用应用；目标机缺失 Runtime 时，安装阶段需要连接 Microsoft 下载服务，或者由管理员预先部署官方 Evergreen Offline Installer。

当前主机只验证了“WebView2 已安装”环境中的应用启动。缺失且联网、缺失且断网两个场景必须在可丢弃 Sandbox/VM 中执行，不得卸载主机 WebView2。结果分别保存到 `qa-results/public-beta/webview2/installed/`、`online/` 和 `offline/`，每份结果不得互相替代。
