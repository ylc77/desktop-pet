# 性能与长时间运行测试

本方案用于开发者复测，不代表当前版本已经完成 1 小时或 8 小时稳定性验证。

## 采样工具

先启动 Release 应用，再运行：

```powershell
.\scripts\windows\monitor-process.ps1 -DurationMinutes 60 -IntervalSeconds 10
```

8 小时测试：

```powershell
.\scripts\windows\monitor-process.ps1 -DurationMinutes 480 -IntervalSeconds 60 -OutputPath .\qa-results\performance\eight-hour.csv
.\scripts\windows\analyze-performance.ps1 -InputPath .\qa-results\performance\eight-hour.csv `
  -OutputPath .\qa-results\performance\performance-summary.md `
  -JsonOutputPath .\qa-results\performance\performance-analysis.json
```

短时自动采样可使用 10–15 分钟；界面循环仍需 Computer Use 或测试者实际操作：

```powershell
.\scripts\windows\monitor-process.ps1 -DurationMinutes 15 -IntervalSeconds 10 -OutputPath .\qa-results\performance\short.csv
.\scripts\windows\analyze-performance.ps1 -InputPath .\qa-results\performance\short.csv -OutputPath .\qa-results\performance\short-summary.md
```

默认聚合 CSV 写入忽略版本控制的 `temp/performance-samples.csv`。每个采样时刻只写一条 `Aggregate` 记录，包含独立 `RunId`、UTC 时间、样本序号、实际间隔，以及 `desktop_pet.exe` 和其全部后代进程（包括 WebView2）的聚合 CPU、Working Set、Private Memory、Handle、Thread、根进程数、WebView2 数和进程总数。同目录还会生成 `*-processes.csv`，保存同一批样本的逐进程明细。

脚本默认拒绝覆盖已有输出；复测时应使用新文件名，只有明确希望覆盖时才传入 `-Overwrite`。每个样本立即落盘，中断后已写入数据仍然存在。目标进程不存在时脚本返回非零退出码。分析器会拒绝混合多个 `RunId`、非单调时间/样本序号以及异常采样间隙，避免把旧运行或不同 PID 行拼成虚假趋势。

## 测试阶段

1. 启动后保持正常动画 10 分钟，记录初始稳定区间。
2. 暂停动画 10 分钟，比较空闲 CPU。
3. 恢复动画并连续执行点击、双击、悬停和拖动。
4. 重载角色包 20 次，观察 Working Set 是否回到稳定范围。
5. 打开和关闭设置面板 100 次。
6. 开启全屏自动隐藏，完成至少 50 次隐藏/恢复循环。
7. 在 1 小时节点记录 CPU、内存、句柄、线程和日志文件大小。
8. 若执行 8 小时测试，在 8 小时节点重复记录并检查趋势。

## 判读

- CPU 应随动画/暂停状态变化，空闲时不应持续高占用。
- Working Set 可因缓存波动，但 Private Memory、Handle 和 Thread 不应持续单调增长。
- 开发者面板显示的解码缓存估算值应受约 `64 MiB` 默认预算约束；角色重载后旧一代缓存引用应释放。
- 角色重载及设置面板循环结束后应回到相近稳定区间。
- 日志单文件不得超过 1 MiB，保留文件不得超过 5 个。
- 出现增长时结合操作时间点排查定时器、事件监听器、图片预加载对象和 WebView2 进程。

报告必须注明采样时长、系统版本、CPU、内存、显示器/DPI、安装包 SHA-256 和实际执行的阶段。未完成 8 小时采样时不得写“8 小时测试通过”。

公开测试版标准输出目录为 `qa-results/public-beta/performance/`，其中包含聚合 `performance.csv`、逐进程 `performance-processes.csv`、`performance-summary.md` 和 `performance-analysis.json`。分析脚本只计算区间、初始值、峰值、结束值和增量；即使 CSV 覆盖 8 小时，状态仍为 `requires_manual_review`，必须结合交互记录、日志轮转、卡顿观察和退出后进程归零后人工判定。
