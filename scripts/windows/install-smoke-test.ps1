[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$InstallerPath,
    [string]$ExpectedVersion,
    [string[]]$InstallerArguments = @('/S'),
    [int]$TimeoutSeconds = 180,
    [switch]$ExpectUpgrade
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
$resolvedInstaller = Resolve-CallerPath -Path $InstallerPath -BaseDirectory $InvocationDirectory
Assert-FileExists $resolvedInstaller 'NSIS installer'
$versionContext = Resolve-DeskPetVersionContext -RepositoryRoot $repo -ReleaseDirectory ([System.IO.Path]::Combine($repo, 'release')) -InstallerPath $resolvedInstaller -ExplicitExpectedVersion $ExpectedVersion
Assert-DeskPetVersionContext -VersionContext $versionContext
$expectedVersion = $versionContext.ExpectedVersion
$beforeProcesses = @(Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue)
$beforeInstalls = @(Get-DeskPetInstallRecords)
$beforeAutostart = @(Get-DeskPetRunEntries)
$settingsPath = Join-Path $env:APPDATA "$script:AppIdentifier\settings.json"
$savedWhatIfPreference = $WhatIfPreference
$WhatIfPreference = $false
try {
    $beforeSettingsHash = if (Test-Path -LiteralPath $settingsPath) { (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash } else { $null }
    $hash = Get-FileHash -LiteralPath $resolvedInstaller -Algorithm SHA256
} finally {
    $WhatIfPreference = $savedWhatIfPreference
}

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
Assert-DeskPetVersionContext -VersionContext $versionContext -RegistryVersions @($afterInstalls | ForEach-Object { [string](Get-ObjectPropertyValue $_ 'DisplayVersion') })
$selection = Select-DeskPetInstallRecord -Records $afterInstalls -ExpectedVersion $expectedVersion
foreach ($evaluation in @($selection.Evaluations | Where-Object { -not $_.Usable })) {
    $report += Write-SmokeResult 'Ignored unusable install registry entry' $true ("display={0}; version={1}; path={2}; reasons={3}" -f $evaluation.DisplayName, $evaluation.DisplayVersion, $evaluation.RedactedInstallLocation, ($evaluation.Reasons -join ' '))
}
$mainExecutable = [string]$selection.ExecutablePath
$report += Write-SmokeResult 'Usable install registry entry' ([bool]$selection.SelectedRecord) "matches=$(@($selection.Evaluations | Where-Object Usable).Count); total=$($afterInstalls.Count); expectedVersion=$expectedVersion"
$report += Write-SmokeResult 'Main executable' ([bool]$mainExecutable -and [System.IO.File]::Exists($mainExecutable)) $(if ($selection.Evaluation) { $selection.Evaluation.RedactedInstallLocation } else { 'No usable InstallLocation was recorded.' })
$report += Write-SmokeResult 'No duplicate autostart' ($afterAutostart.Count -le 1) "count=$($afterAutostart.Count)"
if ($ExpectUpgrade -and $beforeSettingsHash) {
    $afterSettingsHash = if (Test-Path -LiteralPath $settingsPath) { (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash } else { $null }
    $report += Write-SmokeResult 'Upgrade preserved settings' ($afterSettingsHash -eq $beforeSettingsHash) $(if ($afterSettingsHash) { 'Settings SHA-256 unchanged.' } else { 'Settings file missing after upgrade.' })
}
if ($ExpectUpgrade -and $beforeAutostart.Count -eq 1 -and $afterAutostart.Count -eq 1) {
    $registeredPath = ([Environment]::ExpandEnvironmentVariables([string]$afterAutostart[0].Value)).Trim().Trim('"')
    $report += Write-SmokeResult 'Upgrade refreshed autostart path' ([System.IO.File]::Exists($registeredPath)) (ConvertTo-RedactedNativePath $registeredPath)
}
$report | Format-Table -AutoSize
if ($report.Where({ $_.Status -eq 'FAIL' }).Count) { exit 3 }
