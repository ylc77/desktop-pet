[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param([int]$TimeoutSeconds = 180)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
$expectedVersion = Get-DeskPetReleaseVersion -RepositoryRoot $repo

$records = @(Get-DeskPetInstallRecords)
if ($records.Count -eq 0 -and $WhatIfPreference) { Write-Host 'No installed application record; uninstall preview has no action.'; exit 0 }
if (Get-DeskPetRunningProcesses -IncludeLegacy) { throw 'Application is running. Exit through the tray before uninstalling.' }
$selection = Select-DeskPetUninstallRecord -Records $records -ExpectedVersion $expectedVersion
if (-not $selection.SelectedRecord) {
    $details = @($selection.Evaluations | ForEach-Object { "display=$($_.DisplayName); version=$($_.DisplayVersion); reasons=$($_.Reasons -join ' ')" }) -join ' | '
    throw "$(Get-NoAvailableUninstallCommandMessage). records=$($records.Count); $details"
}
$record = $selection.SelectedRecord
$command = $selection.Command
$displayName = [string](Get-ObjectPropertyValue $record 'DisplayName')
$displayVersion = [string](Get-ObjectPropertyValue $record 'DisplayVersion')
$rawInstallLocation = [string](Get-ObjectPropertyValue $record 'InstallLocation')
$installLocation = $null
try { $installLocation = [System.IO.Path]::GetDirectoryName((Join-NativeFileSystemPath $rawInstallLocation 'placeholder.file')) } catch { $installLocation = $null }

Write-Host "Selected application: $displayName $displayVersion"
Write-Host "Selected uninstall command: source=$($command.Source); file=$($command.RedactedFilePath); argumentCount=$($command.ArgumentList.Count)"
if (-not $PSCmdlet.ShouldProcess("$displayName $displayVersion ($($command.RedactedFilePath))", 'Run registered uninstaller')) { exit 0 }
$startParameters = @{ FilePath=$command.FilePath; PassThru=$true }
if ($command.ArgumentList.Count -gt 0) { $startParameters.ArgumentList = $command.ArgumentList }
$process = Start-Process @startParameters
if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { throw "Uninstaller timed out after $TimeoutSeconds seconds." }
if ($process.ExitCode -ne 0) { throw "Uninstaller exited with code $($process.ExitCode)." }
$cleanup = Wait-DeskPetUninstallCleanup -InstallLocation $installLocation -TimeoutSeconds 60 -PollIntervalMilliseconds 500
$cleanupState = $cleanup.State
Write-Host ("Uninstall cleanup completed={0}; timedOut={1}; elapsedMilliseconds={2}; attempts={3}" -f $cleanup.Complete, $cleanup.TimedOut, $cleanup.ElapsedMilliseconds, $cleanup.Attempts)
$dataDirectory = Join-Path $env:APPDATA $script:AppIdentifier
$results = @(
    Write-SmokeResult 'Cleanup completed within 60 seconds' $cleanup.Complete "elapsedMilliseconds=$($cleanup.ElapsedMilliseconds); attempts=$($cleanup.Attempts)"
    Write-SmokeResult 'Uninstall registry removed' ([int]$cleanupState.InstallRecordCount -eq 0) "remaining=$($cleanupState.InstallRecordCount)"
    Write-SmokeResult 'No remaining process' ([int]$cleanupState.ProcessCount -eq 0) "remaining=$($cleanupState.ProcessCount)"
    Write-SmokeResult 'Program directory removed' (-not [bool]$cleanupState.InstallDirectoryExists) $cleanupState.RedactedInstallLocation
    Write-SmokeResult 'Autostart entry removed' ([int]$cleanupState.AutostartEntryCount -eq 0) "remaining=$($cleanupState.AutostartEntryCount)"
    Write-SmokeResult 'Start menu entries removed' ([int]$cleanupState.StartMenuEntryCount -eq 0) "remaining=$($cleanupState.StartMenuEntryCount)"
    Write-SmokeResult 'User settings policy' $true $(if (Test-Path -LiteralPath $dataDirectory) { 'User data retained by design.' } else { 'No user data directory remained.' })
)
$results | Format-Table -AutoSize
if ($results.Where({ $_.Status -eq 'FAIL' }).Count) { exit 2 }
