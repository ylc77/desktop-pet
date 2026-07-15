# 性能与长时间运行测试

本方案用于开发者复测，不代表当前版本已经完成 1 小时或 8 小时稳定性验证。

## 采样工具

先启动 Release 应用，再运行：

```powershell
.\scripts\windows\monitor-process.ps1 -DurationMinutes 60 -IntervalSeconds 10
```

8 小时测试：

```powershell
.\scripts\windows\monitor-process.ps1 -DurationMinutes 480 -IntervalSeconds 30
```

默认 CSV 写入忽略版本控制的 `temp/performance-samples.csv`，字段包括 UTC 时间、PID、归一化 CPU 百分比、Working Set、Private Memory、Handle 数量和 Thread 数量。进程不存在时脚本返回非零退出码。

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
- 角色重载及设置面板循环结束后应回到相近稳定区间。
- 日志单文件不得超过 1 MiB，保留文件不得超过 5 个。
- 出现增长时结合操作时间点排查定时器、事件监听器、图片预加载对象和 WebView2 进程。

报告必须注明采样时长、系统版本、CPU、内存、显示器/DPI、安装包 SHA-256 和实际执行的阶段。未完成 8 小时采样时不得写“8 小时测试通过”。
