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
function Test-Throws([string]$Name, [scriptblock]$Action, [string]$Pattern) {
    try { & $Action; Add-TestResult $Name $false 'No exception was thrown.' }
    catch { Add-TestResult $Name ($_.Exception.Message -match $Pattern) $_.Exception.Message }
}
$exists = { $true }
$expectedVersion = Get-DeskPetReleaseVersion -RepositoryRoot $script:RepositoryRoot

$normalUninstaller = [System.IO.Path]::Combine('C:\Program Files', $script:ProductName, 'uninstall.exe')
$normalRecord = [pscustomobject]@{ QuietUninstallString=''; UninstallString=('"' + $normalUninstaller + '"') }
$normal = Resolve-DeskPetUninstallCommand -Record $normalRecord -FileExists $exists
Test-Equal 'Empty quiet command falls back to normal command' 'UninstallString' $normal.Source
Test-Equal 'Quoted executable path is unwrapped' $normalUninstaller $normal.FilePath
Test-Equal 'Command without arguments produces an empty array' 0 $normal.ArgumentList.Count

$quietRecord = [pscustomobject]@{ QuietUninstallString=('"' + $normalUninstaller + '" /S'); UninstallString='"C:\Fallback\uninstall.exe"' }
$quiet = Resolve-DeskPetUninstallCommand -Record $quietRecord -FileExists $exists
Test-Equal 'Valid quiet command takes precedence' 'QuietUninstallString' $quiet.Source
Test-Equal 'Quiet command keeps its registered arguments' '/S' $quiet.ArgumentList[0]

$invalidQuietRecord = [pscustomobject]@{ QuietUninstallString='not-a-command'; UninstallString='"C:\Valid\uninstall.exe"' }
$invalidQuiet = Resolve-DeskPetUninstallCommand -Record $invalidQuietRecord -FileExists $exists
Test-Equal 'Invalid quiet command falls back to normal command' 'UninstallString' $invalidQuiet.Source

Test-Throws 'Both uninstall commands empty' {
    Resolve-DeskPetUninstallCommand -Record ([pscustomobject]@{ QuietUninstallString=' '; UninstallString=$null }) -FileExists $exists
} ([regex]::Escape((Get-NoAvailableUninstallCommandMessage)))

$chineseWords = -join @([char]0x684C,[char]0x5BA0,' ',[char]0x6D4B,[char]0x8BD5,'\',[char]0x5378,[char]0x8F7D,[char]0x7A0B,[char]0x5E8F)
$chinesePath = 'C:\' + $chineseWords + '\uninstall.exe'
$chinese = ConvertFrom-NativeCommandLine ('"' + $chinesePath + '" /LANG=zh_CN /PROMPT')
Test-Equal 'Chinese path with spaces parses safely' $chinesePath $chinese.FilePath
Test-Equal 'Command arguments remain separate from executable path' '/LANG=zh_CN /PROMPT' $chinese.ArgumentList[0]

$records = @(
    [pscustomobject]@{ DisplayName=$script:ProductName; DisplayVersion='0.0.9'; QuietUninstallString=''; UninstallString='"Z:\Old\uninstall.exe"'; PSPath='Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\Old' },
    [pscustomobject]@{ DisplayName=$script:ProductName; DisplayVersion=$expectedVersion; QuietUninstallString=''; UninstallString='"C:\Current\uninstall.exe"'; PSPath='Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER\Current' }
)
$selection = Select-DeskPetUninstallRecord -Records $records -ExpectedVersion $expectedVersion -FileExists $exists
Test-Equal 'Multiple records select matching current version' 'C:\Current\uninstall.exe' $selection.Command.FilePath
Test-Equal 'Multiple records prefer current-user record' $true $selection.Evaluation.CurrentUser
Test-Equal 'Old version is marked unusable' $false $selection.Evaluations[0].Usable

$reportRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'desk-pet-uninstall-report-test-' + [guid]::NewGuid().ToString('N'))
try {
    $failed = [pscustomobject]@{ name='Uninstall application'; category='current-machine'; status='failed'; command=''; details='simulated exit code 1' }
    Write-QAResultArtifacts -OutputDirectory $reportRoot -Results @($failed) -Mode CurrentMachine -Phase uninstallation -FailureMessage 'simulated failure' -Transaction ([ordered]@{ uninstallRecordCount=1; processCount=0 })
    $jsonPath = [System.IO.Path]::Combine($reportRoot, 'qa-results.json')
    $statePath = [System.IO.Path]::Combine($reportRoot, 'current-machine-state.json')
    $reported = [System.IO.File]::Exists($jsonPath) -and [System.IO.File]::Exists($statePath)
    $data = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Equal 'Uninstall failure still writes complete report artifacts' $true $reported
    Test-Equal 'Uninstall failure remains failed in report' 'failed' ([string]$data.status)
} finally {
    if ([System.IO.Directory]::Exists($reportRoot)) { [System.IO.Directory]::Delete($reportRoot, $true) }
}

$results | Format-Table -AutoSize
$hostIsPowerShell51 = $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
[pscustomobject]@{ Name='Windows PowerShell 5.1 host'; Passed=$hostIsPowerShell51; Details=$PSVersionTable.PSVersion.ToString() } | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -or -not $hostIsPowerShell51) { exit 1 }
