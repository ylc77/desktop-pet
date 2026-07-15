[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$InstallerPath,
    [string[]]$InstallPaths = @(
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('Qzpc5qGM5a6gIOa1i+ivlQ==')),
        'C:\Program Files\Desk Pet Test',
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('QzpcUUFc6L+Z5piv5LiA5Liq55So5LqO6aqM6K+B6L6D6ZW/5a6J6KOF6Lev5b6E5ZKM5Lit5paH6Lev5b6E5YW85a655oCn55qE5qGM5a6g5rWL6K+V55uu5b2V'))
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$installer = (Resolve-Path -LiteralPath $InstallerPath).Path
$results = @()
Write-Warning 'This test installs and uninstalls the app once per listed path. Program Files may trigger UAC; do not bypass it.'
if ($WhatIfPreference) {
    $InstallPaths | ForEach-Object { Write-Host "Would test isolated install path: $_" }
    exit 0
}
foreach ($installPath in $InstallPaths) {
    if (-not $PSCmdlet.ShouldProcess($installPath, 'Install, launch twice, wait for normal exit, inspect data/logs, and uninstall')) {
        $results += Write-SmokeResult $installPath $true 'Preview only; no path was created.'
        continue
    }
    & "$PSScriptRoot\install-smoke-test.ps1" -InstallerPath $installer -InstallerArguments @('/S', "/D=$installPath") -Confirm:$false
    $exe = Join-Path $installPath 'desk-pet-framework.exe'
    & "$PSScriptRoot\process-smoke-test.ps1" -ExecutablePath $exe -ManualExitTimeoutSeconds 120 -Confirm:$false
    $config = Join-Path $env:APPDATA "$script:AppIdentifier\settings.json"
    $logs = Join-Path $env:LOCALAPPDATA $script:AppIdentifier
    $resourcesOkay = Test-Path -LiteralPath $exe
    $settingsOkay = (Test-Path -LiteralPath (Split-Path -Parent $config)) -or -not (Test-Path -LiteralPath $config)
    $logsOkay = Test-Path -LiteralPath $logs
    $results += Write-SmokeResult "$installPath executable/resources" $resourcesOkay $exe
    $results += Write-SmokeResult "$installPath settings directory" $settingsOkay (Split-Path -Parent $config)
    $results += Write-SmokeResult "$installPath log directory" $logsOkay $logs
    & "$PSScriptRoot\uninstall-smoke-test.ps1" -Confirm:$false
    $results += Write-SmokeResult "$installPath removed" (-not (Test-Path -LiteralPath $installPath)) $installPath
}
$results | Format-Table -AutoSize
if (@($results | Where-Object Status -eq 'FAIL').Count) { exit 2 }
