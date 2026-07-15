[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$PreviousInstallerPath,
    [Parameter(Mandatory)][string]$InstallerPath,
    [string]$OutputDirectory,
    [int]$TimeoutSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = [System.IO.Path]::Combine($repo, 'qa-results', 'public-beta', 'upgrade') }
$previous = (Resolve-Path -LiteralPath $PreviousInstallerPath).Path
$current = (Resolve-Path -LiteralPath $InstallerPath).Path
Assert-FileExists $previous 'Previous NSIS installer'
Assert-FileExists $current 'Current NSIS installer'
$previousHash = (Get-FileHash -LiteralPath $previous -Algorithm SHA256).Hash
$currentHash = (Get-FileHash -LiteralPath $current -Algorithm SHA256).Hash
if ($previousHash -eq $currentHash) { throw 'PreviousInstallerPath and InstallerPath resolve to identical artifacts; this is not an upgrade test.' }
$output = [System.IO.Path]::GetFullPath($OutputDirectory)
[System.IO.Directory]::CreateDirectory($output) | Out-Null
$reportPath = [System.IO.Path]::Combine($output, 'upgrade-result.json')
$settingsPath = Join-Path $env:APPDATA "$script:AppIdentifier\settings.json"
$state = [ordered]@{ phase='preview'; status='not_executed'; startedAtUtc=[DateTime]::UtcNow.ToString('o'); previousInstallerSha256=$previousHash; installerSha256=$currentHash; checks=@(); recoveryCommands=@('.\scripts\windows\uninstall-smoke-test.ps1 -WhatIf') }

if ($WhatIfPreference) {
    Write-Host "Upgrade preview: previous=$(Split-Path $previous -Leaf); current=$(Split-Path $current -Leaf); output=$output"
    Write-Host 'Would install the previous version, require non-sensitive settings preparation and normal exit, install the current version without uninstalling first, verify preservation and duplicates, then uninstall.'
    $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    exit 0
}
if ($env:DESK_PET_QA_CLEAN_ENVIRONMENT -ne '1') { throw 'Real upgrade QA requires DESK_PET_QA_CLEAN_ENVIRONMENT=1 in an explicitly designated disposable environment.' }
if (-not $PSCmdlet.ShouldProcess('Disposable Windows QA environment', 'Install old version, upgrade in place, verify state, and uninstall')) { exit 0 }

function Invoke-Installer([string]$Path) {
    $process = Start-Process -FilePath $Path -ArgumentList @('/S') -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { throw "Installer timed out: $(Split-Path $Path -Leaf)" }
    if ($process.ExitCode -ne 0) { throw "Installer failed with exit code $($process.ExitCode): $(Split-Path $Path -Leaf)" }
}

try {
    $state.phase = 'install-previous'
    Invoke-Installer $previous
    $oldRecords = @(Get-DeskPetInstallRecords -IncludeLegacy)
    if ($oldRecords.Count -ne 1) { throw "Expected one previous-version install record; found $($oldRecords.Count)." }
    $oldVersion = [string](Get-ObjectPropertyValue $oldRecords[0] 'DisplayVersion')
    $currentVersion = Get-DeskPetReleaseVersion -RepositoryRoot $repo
    if ($oldVersion -eq $currentVersion) { throw "Installed previous version is $oldVersion, the same as the current Release. Same-version reinstall is not an upgrade test." }
    $oldDisplayName = [string](Get-ObjectPropertyValue $oldRecords[0] 'DisplayName')
    $oldExecutableName = if ($oldDisplayName -eq $script:ProductName) { $script:ExecutableName } else { [string]$script:LegacyExecutableNames[0] }
    $oldExe = Join-NativeFileSystemPath ([string](Get-ObjectPropertyValue $oldRecords[0] 'InstallLocation')) $oldExecutableName
    if (-not [System.IO.File]::Exists($oldExe)) { throw 'Previous-version executable was not found.' }
    Start-Process -FilePath $oldExe
    Write-Host 'Set non-sensitive window position, scale, always-on-top, and autostart values in the old version. Exit normally, then press Enter.'
    Read-Host | Out-Null
    if (Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue) { throw 'Previous version is still running; normal exit is required before upgrade.' }
    $beforeSettingsHash = if ([System.IO.File]::Exists($settingsPath)) { (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash } else { $null }
    if ([string]::IsNullOrWhiteSpace($beforeSettingsHash)) { throw 'The settings file was not created by the previous version.' }
    $beforeAutostart = @(Get-DeskPetRunEntries)

    $state.phase = 'install-current-over-previous'
    Invoke-Installer $current
    $records = @(Get-DeskPetInstallRecords -IncludeLegacy)
    $selection = Select-DeskPetInstallRecord -Records $records -ExpectedVersion $currentVersion
    $afterSettingsHash = if ([System.IO.File]::Exists($settingsPath)) { (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash } else { $null }
    $afterAutostart = @(Get-DeskPetRunEntries)
    $state.checks = @(
        [ordered]@{ name='Current version record'; passed=[bool]$selection.SelectedRecord; details="records=$($records.Count); expected=$currentVersion" },
        [ordered]@{ name='Settings preserved byte-for-byte'; passed=$beforeSettingsHash -eq $afterSettingsHash; details='SHA-256 comparison of non-sensitive settings.' },
        [ordered]@{ name='Single uninstall record'; passed=$records.Count -eq 1; details="count=$($records.Count)" },
        [ordered]@{ name='No duplicate autostart'; passed=$afterAutostart.Count -le 1; details="before=$($beforeAutostart.Count); after=$($afterAutostart.Count)" }
    )
    if (@($state.checks | Where-Object { -not $_.passed }).Count) { throw 'One or more upgrade assertions failed.' }

    $state.phase = 'uninstall-current'
    & "$PSScriptRoot\uninstall-smoke-test.ps1" -Confirm:$false
    if ($LASTEXITCODE -ne 0) { throw 'Current-version uninstall failed after upgrade.' }
    & "$PSScriptRoot\check-leftovers.ps1"
    if ($LASTEXITCODE -ne 0) { throw 'Post-upgrade uninstall leftovers were detected.' }
    $state.phase = 'completed'
    $state.status = 'passed'
} catch {
    $state.status = 'failed'
    $state['failure'] = $_.Exception.Message
    throw
} finally {
    $state['finishedAtUtc'] = [DateTime]::UtcNow.ToString('o')
    $state['remainingInstallRecords'] = @(Get-DeskPetInstallRecords).Count
    $state['remainingProcesses'] = @(Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue).Count
    $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportPath -Encoding UTF8
}
