[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param([int]$TimeoutSeconds = 180)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

$records = @(Get-DeskPetInstallRecords)
if ($records.Count -eq 0 -and $WhatIfPreference) { Write-Host 'No installed application record; uninstall preview has no action.'; exit 0 }
if ($records.Count -ne 1) { throw "Expected one installed application record; found $($records.Count)." }
if (Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue) { throw 'Application is running. Exit through the tray before uninstalling.' }
$record = $records[0]
$installLocation = [string]$record.InstallLocation
$commandLine = if ($record.QuietUninstallString) { [string]$record.QuietUninstallString } else { [string]$record.UninstallString }
if ($commandLine -notmatch '^\s*"([^"]+)"\s*(.*)$' -and $commandLine -notmatch '^\s*(\S+)\s*(.*)$') { throw 'Cannot safely parse uninstall command.' }
$uninstaller = $Matches[1]
$arguments = $Matches[2]

if (-not $PSCmdlet.ShouldProcess($uninstaller, 'Run registered uninstaller')) { Write-Host "Would run: $uninstaller $arguments"; exit 0 }
$process = Start-Process -FilePath $uninstaller -ArgumentList $arguments -PassThru -WindowStyle Hidden
if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { throw "Uninstaller timed out after $TimeoutSeconds seconds." }
if ($process.ExitCode -ne 0) { throw "Uninstaller exited with code $($process.ExitCode)." }
$remaining = @(Get-DeskPetInstallRecords)
$running = @(Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue)
$autostart = @(Get-DeskPetRunEntries)
$dataDirectory = Join-Path $env:APPDATA $script:AppIdentifier
$results = @(
    Write-SmokeResult 'Uninstall registry removed' ($remaining.Count -eq 0) "remaining=$($remaining.Count)"
    Write-SmokeResult 'No remaining process' ($running.Count -eq 0) "remaining=$($running.Count)"
    Write-SmokeResult 'Program directory removed' (-not $installLocation -or -not (Test-Path -LiteralPath $installLocation)) $(if ($installLocation) { $installLocation } else { 'InstallLocation was empty.' })
    Write-SmokeResult 'Autostart entry removed' ($autostart.Count -eq 0) "remaining=$($autostart.Count)"
    Write-SmokeResult 'User settings policy' $true $(if (Test-Path -LiteralPath $dataDirectory) { 'User data retained by design.' } else { 'No user data directory remained.' })
)
$results | Format-Table -AutoSize
if ($results.Where({ $_.Status -eq 'FAIL' }).Count) { exit 2 }
