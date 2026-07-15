[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

$installs = @(Get-DeskPetInstallRecords -IncludeLegacy)
$autostart = @(Get-DeskPetRunEntries -IncludeLegacy)
$processes = @(Get-DeskPetRunningProcesses -IncludeLegacy)
$dataDirectory = Join-Path $env:LOCALAPPDATA $script:AppIdentifier
$startMenuMatches = @(Get-DeskPetStartMenuEntries -IncludeLegacy)

$results = @(
    Write-SmokeResult 'No installed application record' ($installs.Count -eq 0) "count=$($installs.Count)"
    Write-SmokeResult 'No autostart entry' ($autostart.Count -eq 0) "count=$($autostart.Count)"
    Write-SmokeResult 'No running process' ($processes.Count -eq 0) "count=$($processes.Count)"
    Write-SmokeResult 'No Start Menu shortcut' ($startMenuMatches.Count -eq 0) "count=$($startMenuMatches.Count)"
    Write-SmokeResult 'User data policy' $true $(if (Test-Path -LiteralPath $dataDirectory) { 'Application data remains by design; remove it manually only when the user requests local-data deletion.' } else { 'No application data directory found.' })
)
$results | Format-Table -AutoSize
if ($results[0..3].Where({ $_.Status -eq 'FAIL' }).Count) { exit 2 }
