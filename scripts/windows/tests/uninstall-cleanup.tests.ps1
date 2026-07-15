[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\common.ps1"

$results = @()
function Add-TestResult([string]$Name, [bool]$Passed, [string]$Details) {
    $script:results += [pscustomobject]@{ Name=$Name; Passed=$Passed; Details=$Details }
}
function Test-Equal([string]$Name, [object]$Expected, [object]$Actual) {
    Add-TestResult $Name ($Expected -eq $Actual) "expected=$Expected; actual=$Actual"
}
function New-CleanupState([int]$Records, [int]$Processes, [bool]$Directory, [int]$Autostart, [int]$StartMenu) {
    [pscustomobject]@{
        InstallRecordCount=$Records; ProcessCount=$Processes; InstallDirectoryExists=$Directory
        AutostartEntryCount=$Autostart; StartMenuEntryCount=$StartMenu; RedactedInstallLocation='<test>'
    }
}

$expectedProductName = -join @([char]0x4E03, [char]0x9171, [char]0x684C, [char]0x5BA0)
$immediateLocation = [System.IO.Path]::Combine('C:\Program Files', $expectedProductName)
$immediate = Wait-DeskPetUninstallCleanup -InstallLocation $immediateLocation -TimeoutSeconds 1 `
    -Probe { New-CleanupState 0 0 $false 0 0 } -Delay { throw 'Immediate cleanup must not delay.' } -GetElapsedMilliseconds { 0 }
Test-Equal 'Uninstall cleanup can complete immediately' $true $immediate.Complete
Test-Equal 'Immediate cleanup uses one probe' 1 $immediate.Attempts

$delayedClock = 0
$delayedCalls = 0
$delayedProbe = {
    param($Path)
    $script:delayedCalls++
    if ($script:delayedCalls -lt 3) { return New-CleanupState 1 0 $true 0 1 }
    return New-CleanupState 0 0 $false 0 0
}
$delayedDelay = { param($Milliseconds) $script:delayedClock += $Milliseconds }
$delayedElapsed = { $script:delayedClock }
$delayed = Wait-DeskPetUninstallCleanup -InstallLocation $immediateLocation -TimeoutSeconds 3 `
    -Probe $delayedProbe -Delay $delayedDelay -GetElapsedMilliseconds $delayedElapsed
Test-Equal 'Delayed uninstall cleanup eventually passes' $true $delayed.Complete
Test-Equal 'Delayed uninstall cleanup reports elapsed time' 1000 $delayed.ElapsedMilliseconds
Test-Equal 'Delayed uninstall cleanup probes until clean' 3 $delayed.Attempts

$timeoutClock = 0
$timeoutDelay = { param($Milliseconds) $script:timeoutClock += $Milliseconds }
$timeoutElapsed = { $script:timeoutClock }
$timedOut = Wait-DeskPetUninstallCleanup -InstallLocation $immediateLocation -TimeoutSeconds 1 `
    -Probe { New-CleanupState 1 1 $true 1 1 } -Delay $timeoutDelay -GetElapsedMilliseconds $timeoutElapsed
Test-Equal 'Uninstall cleanup times out when leftovers remain' $true $timedOut.TimedOut
Test-Equal 'Timeout retains the final leftover state' 1 $timedOut.State.InstallRecordCount
Test-Equal 'Timeout is capped at the configured duration' 1000 $timedOut.ElapsedMilliseconds

$unicodePrefix = -join @([char]0x684C, [char]0x5BA0, ' ', [char]0x6D4B, [char]0x8BD5)
$unicodeLocation = [System.IO.Path]::Combine('C:\' + $unicodePrefix, $expectedProductName)
$observedLocation = $null
$unicodeProbe = { param($Path) $script:observedLocation = $Path; New-CleanupState 0 0 $false 0 0 }
$unicode = Wait-DeskPetUninstallCleanup -InstallLocation $unicodeLocation -TimeoutSeconds 1 `
    -Probe $unicodeProbe -Delay { throw 'Unicode cleanup must not delay.' } -GetElapsedMilliseconds { 0 }
Test-Equal 'Cleanup preserves Chinese paths with spaces' $unicodeLocation $observedLocation
Test-Equal 'Chinese path cleanup completes' $true $unicode.Complete
Test-Equal 'Current DisplayName is used' $expectedProductName $script:ProductName
Test-Equal 'Current executable is used' 'desktop_pet.exe' $script:ExecutableName

$results | Format-Table -AutoSize
$hostIsPowerShell51 = $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
[pscustomobject]@{ Name='Windows PowerShell 5.1 host'; Passed=$hostIsPowerShell51; Details=$PSVersionTable.PSVersion.ToString() } | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -or -not $hostIsPowerShell51) { exit 1 }
