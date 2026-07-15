[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$InstallerPath,
    [string[]]$InstallerArguments = @('/S'),
    [int]$TimeoutSeconds = 180,
    [switch]$ExpectUpgrade
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

$resolvedInstaller = (Resolve-Path -LiteralPath $InstallerPath).Path
Assert-FileExists $resolvedInstaller 'NSIS installer'
$beforeProcesses = @(Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue)
$beforeInstalls = @(Get-DeskPetInstallRecords)
$beforeAutostart = @(Get-DeskPetRunEntries)
$settingsPath = Join-Path $env:APPDATA "$script:AppIdentifier\settings.json"
$beforeSettingsHash = if (Test-Path -LiteralPath $settingsPath) { (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash } else { $null }
$hash = Get-FileHash -LiteralPath $resolvedInstaller -Algorithm SHA256

$report = @(
    Write-SmokeResult 'Installer exists' $true (Split-Path $resolvedInstaller -Leaf)
    Write-SmokeResult 'Installer SHA-256' $true $hash.Hash
    Write-SmokeResult 'No running old process' ($beforeProcesses.Count -eq 0) "count=$($beforeProcesses.Count)"
    Write-SmokeResult 'Previous installs recorded' $true "count=$($beforeInstalls.Count)"
    Write-SmokeResult 'Previous autostart recorded' $true "count=$($beforeAutostart.Count)"
    Write-SmokeResult 'Previous settings recorded' $true $(if ($beforeSettingsHash) { 'SHA-256 captured.' } else { 'No settings file.' })
)

if ($beforeProcesses.Count -gt 0) { $report | Format-Table -AutoSize; exit 2 }
if (-not $PSCmdlet.ShouldProcess($resolvedInstaller, "Run NSIS installer with arguments: $($InstallerArguments -join ' ')")) {
    $report | Format-Table -AutoSize
    exit 0
}

$process = Start-Process -FilePath $resolvedInstaller -ArgumentList $InstallerArguments -PassThru -WindowStyle Hidden
if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { throw "Installer timed out after $TimeoutSeconds seconds." }
if ($process.ExitCode -ne 0) { throw "Installer exited with code $($process.ExitCode)." }

$afterInstalls = @(Get-DeskPetInstallRecords)
$afterAutostart = @(Get-DeskPetRunEntries)
$install = $afterInstalls | Select-Object -First 1
$mainExecutable = if ($install -and $install.InstallLocation) { Join-Path $install.InstallLocation 'desk-pet-framework.exe' } else { $null }
$report += Write-SmokeResult 'Install registry entry' ($afterInstalls.Count -eq 1) "count=$($afterInstalls.Count)"
$report += Write-SmokeResult 'Main executable' ([bool]$mainExecutable -and (Test-Path -LiteralPath $mainExecutable)) $(if ($mainExecutable) { $mainExecutable } else { 'InstallLocation was not recorded.' })
$report += Write-SmokeResult 'No duplicate autostart' ($afterAutostart.Count -le 1) "count=$($afterAutostart.Count)"
if ($ExpectUpgrade -and $beforeSettingsHash) {
    $afterSettingsHash = if (Test-Path -LiteralPath $settingsPath) { (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash } else { $null }
    $report += Write-SmokeResult 'Upgrade preserved settings' ($afterSettingsHash -eq $beforeSettingsHash) $(if ($afterSettingsHash) { 'Settings SHA-256 unchanged.' } else { 'Settings file missing after upgrade.' })
}
if ($ExpectUpgrade -and $beforeAutostart.Count -eq 1 -and $afterAutostart.Count -eq 1) {
    $registeredPath = $afterAutostart[0].Value.Trim('"')
    $report += Write-SmokeResult 'Upgrade refreshed autostart path' (Test-Path -LiteralPath $registeredPath) $registeredPath
}
$report | Format-Table -AutoSize
if ($report.Where({ $_.Status -eq 'FAIL' }).Count) { exit 3 }
