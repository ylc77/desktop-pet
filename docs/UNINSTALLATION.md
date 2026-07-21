# 退出与卸载

先通过桌宠右键菜单或系统托盘正常退出，确认任务管理器中没有 `desktop_pet.exe`，再从 Windows“已安装的应用”或开始菜单中的“七酱桌宠”卸载入口启动卸载器。

正常卸载应移除：

- 主程序安装目录；
- 开始菜单快捷方式；
- 开机启动项；
- 卸载注册表记录；
- 运行进程。

设置、日志和从外观中心导入的本地角色默认保留，以便重新安装后继续使用。需要彻底删除时，用户可在应用退出并确认路径后手动删除：

- `%APPDATA%\dev.deskpet.framework`
- `%LOCALAPPDATA%\dev.deskpet.framework`

不得删除其父目录。当前 QA 流程使用最长 60 秒的有界卸载清理轮询，但 `0.3.0` 的真实 CurrentMachine 卸载仍需用户确认后复测。诊断预览命令：

```powershell
.\scripts\windows\run-qa-suite.ps1 -Mode CurrentMachine -ResumeFromPhase Uninstallation -WhatIf
```

已经完成安装但尚未完成安装后检查时，先使用现有安装预览模式。该模式不会再次运行安装器；调度器只解析一次 Release 版本，并把同一个 `ExpectedVersion` 传给安装记录选择、运行检查和卸载脚本。用户传入的相对路径始终以调用脚本时的 PowerShell 当前目录为基准，不受提权进程、桌面或 System32 工作目录影响。

```powershell
.\scripts\windows\run-qa-suite.ps1 `
  -Mode CurrentMachine `
  -UseExistingInstallation `
  -InstallerPath ".\release\updater\0.3.0\qijiang-desktop-pet_0.3.0_x64-setup.exe" `
  -OutputDirectory ".\qa-results-current-machine-0.3.0-resume" `
  -WhatIf
```

移除 `-WhatIf` 后才会启动现有安装、执行人工托盘退出检查并调用已注册卸载器。卸载器退出后每 500 ms 检查一次清理状态，最多等待 60 秒；脚本不会主动删除残留。
