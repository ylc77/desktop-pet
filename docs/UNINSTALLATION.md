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

不得删除其父目录。当前 0.1.0 的最新真实卸载 QA 仍发现程序目录、快捷方式和卸载记录残留，因此公开测试前必须重新修复并验证。诊断预览命令：

```powershell
.\scripts\windows\run-qa-suite.ps1 -Mode CurrentMachine -ResumeFromPhase Uninstallation -WhatIf
```
