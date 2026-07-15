[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [int]$StartupSeconds = 3,
    [int]$ManualExitTimeoutSeconds = 30,
    [switch]$AllowForceCleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$executable = (Resolve-Path -LiteralPath $ExecutablePath).Path
Assert-FileExists $executable 'Application executable'
if (Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue) { throw 'A desk pet process is already running.' }
if (-not $PSCmdlet.ShouldProcess($executable, 'Launch twice to verify single-instance behavior')) { exit 0 }

Start-Process -FilePath $executable -WindowStyle Hidden
Start-Sleep -Seconds $StartupSeconds
Start-Process -FilePath $executable -WindowStyle Hidden
Start-Sleep -Seconds $StartupSeconds
$instances = @(Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue)
$singleInstance = $instances.Count -eq 1
Write-SmokeResult 'Single instance after second launch' $singleInstance "count=$($instances.Count)" | Format-Table -AutoSize
if (-not $singleInstance) { if ($AllowForceCleanup) { $instances | Stop-Process -Force }; exit 2 }

Write-Host "Exit the application normally from its tray or context menu within $ManualExitTimeoutSeconds seconds."
$deadline = [DateTime]::UtcNow.AddSeconds($ManualExitTimeoutSeconds)
while ([DateTime]::UtcNow -lt $deadline -and (Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 500 }
$remaining = @(Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue)
if ($remaining.Count -gt 0 -and $AllowForceCleanup) { $remaining | Stop-Process -Force }
Write-SmokeResult 'Normal exit leaves no process' ($remaining.Count -eq 0) "remaining=$($remaining.Count)" | Format-Table -AutoSize
if ($remaining.Count -gt 0) { exit 3 }
