[CmdletBinding()]
param([string]$ResultRoot = 'C:\DeskPetQA\Results')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\common.ps1"
$appData = Join-Path $env:APPDATA $script:AppIdentifier
$localData = Join-Path $env:LOCALAPPDATA $script:AppIdentifier
[ordered]@{
    collectedAtUtc=[DateTime]::UtcNow.ToString('o')
    os=Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture
    appDataExists=Test-Path -LiteralPath $appData
    localDataExists=Test-Path -LiteralPath $localData
    runningProcesses=@(Get-DeskPetRunningProcesses -IncludeLegacy).Count
    note='Sandbox represents this host Windows generation only; it is not both Windows 10 and Windows 11.'
} | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $ResultRoot 'sandbox-summary.json')
