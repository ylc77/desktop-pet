[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

$settingsPath = [System.IO.Path]::Combine($env:APPDATA, $script:AppIdentifier, 'settings.json')
$logDirectory = [System.IO.Path]::Combine($env:LOCALAPPDATA, $script:AppIdentifier, 'logs')
$settingsValid = $true
$settingsDetails = 'Settings file has not been created yet.'
if ([System.IO.File]::Exists($settingsPath)) {
    try {
        $null = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $settingsDetails = 'Existing settings JSON is valid.'
    } catch {
        $settingsValid = $false
        $settingsDetails = 'Existing settings JSON is invalid.'
    }
}
$logCount = if ([System.IO.Directory]::Exists($logDirectory)) { @(Get-ChildItem -LiteralPath $logDirectory -File -ErrorAction SilentlyContinue).Count } else { 0 }
$results = @(
    Write-SmokeResult 'Settings storage is readable' $settingsValid $settingsDetails
    Write-SmokeResult 'Log storage inspected' $true "logFiles=$logCount; path=%LOCALAPPDATA%\$script:AppIdentifier\logs"
)
$results | Format-Table -AutoSize
if (@($results | Where-Object Status -eq 'FAIL').Count) { exit 2 }
