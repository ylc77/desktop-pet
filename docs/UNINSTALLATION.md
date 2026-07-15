# 退出与卸载

先通过桌宠右键菜单或系统托盘正常退出，确认任务管理器中没有 `desktop_pet.exe`，再从 Windows“已安装的应用”或开始菜单中的“七酱桌宠”卸载入口启动卸载器。

正常卸载应移除：

- 主程序安装目录；
- 开始菜单快捷方式；
- 开机启动项；
- 卸载注册表记录；
- 运行进程。

设置和日志默认保留。需要彻底删除时，用户可在应用退出并确认路径后手动删除：

- `%APPDATA%\dev.deskpet.framework`
- `%LOCALAPPDATA%\dev.deskpet.framework`

不得删除其父目录。`0.1.0-beta.1-rc.1` 已增加最长 60 秒的卸载清理轮询，但真实 CurrentMachine 卸载仍需用户确认后复测。诊断预览命令：

```powershell
.\scripts\windows\run-qa-suite.ps1 -Mode CurrentMachine -ResumeFromPhase Uninstallation -WhatIf
```
