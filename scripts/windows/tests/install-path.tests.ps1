[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$commonPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', 'common.ps1'))
. $commonPath

$results = @()
function Add-TestResult([string]$Name, [bool]$Passed, [string]$Details) {
    $script:results += [pscustomobject]@{ Name=$Name; Passed=$Passed; Details=$Details }
}
function Test-Equal([string]$Name, [object]$Expected, [object]$Actual) {
    Add-TestResult $Name ($Expected -eq $Actual) "expected=$Expected; actual=$Actual"
}
function Test-Throws([string]$Name, [scriptblock]$Action, [string]$Pattern) {
    try {
        & $Action
        Add-TestResult $Name $false 'No exception was thrown.'
    } catch {
        Add-TestResult $Name ($_.Exception.Message -match $Pattern) $_.Exception.Message
    }
}

Test-Equal 'Valid Program Files path' 'C:\Program Files\Desk Pet Framework\desk-pet-framework.exe' (Join-NativeFileSystemPath 'C:\Program Files\Desk Pet Framework' 'desk-pet-framework.exe')
Test-Equal 'Trailing backslash' 'C:\Program Files\Desk Pet Framework\desk-pet-framework.exe' (Join-NativeFileSystemPath 'C:\Program Files\Desk Pet Framework\' 'desk-pet-framework.exe')
Test-Equal 'Quoted path' 'C:\Program Files\Desk Pet Framework\desk-pet-framework.exe' (Join-NativeFileSystemPath '"C:\Program Files\Desk Pet Framework"' 'desk-pet-framework.exe')
Test-Equal 'Chinese and spaces' 'C:\桌宠 测试\Desk Pet Framework\desk-pet-framework.exe' (Join-NativeFileSystemPath 'C:\桌宠 测试\Desk Pet Framework' 'desk-pet-framework.exe')
Test-Throws 'Empty InstallLocation' { Join-NativeFileSystemPath '' 'desk-pet-framework.exe' } 'InstallLocation is empty'
Test-Throws 'Relative InstallLocation' { Join-NativeFileSystemPath '.\Desk Pet Framework' 'desk-pet-framework.exe' } 'not an absolute path'

$directoryExists = { param($Path) $Path -eq 'C:\Valid\Desk Pet Framework' }
$fileExists = { param($Path) $Path -eq 'C:\Valid\Desk Pet Framework\desk-pet-framework.exe' }
$records = @(
    [pscustomobject]@{ DisplayName='Desk Pet Framework'; DisplayVersion='0.1.0'; InstallLocation='Z:\Old Desk Pet'; PSPath='Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\Old' },
    [pscustomobject]@{ DisplayName='Desk Pet Framework'; DisplayVersion='0.1.0'; InstallLocation='C:\Valid\Desk Pet Framework\'; PSPath='Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER\Valid' }
)
$selection = Select-DeskPetInstallRecord -Records $records -ExpectedVersion '0.1.0' -DirectoryExists $directoryExists -FileExists $fileExists
Test-Equal 'Second valid record selected after stale first record' 'C:\Valid\Desk Pet Framework\desk-pet-framework.exe' $selection.ExecutablePath
Test-Equal 'Unavailable drive record marked unusable' $false $selection.Evaluations[0].Usable
Test-Equal 'Current-user record preferred' $true $selection.Evaluation.CurrentUser

$missingExecutable = Select-DeskPetInstallRecord -Records @([pscustomobject]@{
    DisplayName='Desk Pet Framework'; DisplayVersion='0.1.0'; InstallLocation='C:\Installed'; PSPath='Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER\MissingExe'
}) -ExpectedVersion '0.1.0' -DirectoryExists { $true } -FileExists { $false }
Test-Equal 'Installed record without main executable fails selection' $null $missingExecutable.SelectedRecord

$isolatedResult = & {
    function Get-PSDrive { return $null }
    if ($null -ne (Get-PSDrive -Name C -ErrorAction SilentlyContinue)) { throw 'The isolated PSDrive simulation failed.' }
    Join-NativeFileSystemPath 'C:\Program Files\Desk Pet Framework' 'desk-pet-framework.exe'
}
Test-Equal 'Native combine is independent of a C PSDrive' 'C:\Program Files\Desk Pet Framework\desk-pet-framework.exe' ([string]$isolatedResult)

$reportRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'desk-pet-qa-report-test-' + [guid]::NewGuid().ToString('N'))
try {
    $failedResult = [pscustomobject]@{ name='Synthetic failure'; category='transaction'; status='failed'; command=''; details='simulated' }
    $transaction = [ordered]@{ phase='installation'; installationDetected=$true; processCount=0; uninstallRecordCount=1 }
    Write-QAResultArtifacts -OutputDirectory $reportRoot -Results @($failedResult) -Mode CurrentMachine -Phase installation -FailureMessage 'simulated failure' -Transaction $transaction
    $artifactsExist = [System.IO.File]::Exists([System.IO.Path]::Combine($reportRoot, 'qa-results.json')) -and
        [System.IO.File]::Exists([System.IO.Path]::Combine($reportRoot, 'qa-summary.md')) -and
        [System.IO.File]::Exists([System.IO.Path]::Combine($reportRoot, 'current-machine-state.json'))
    $reportData = Get-Content -LiteralPath ([System.IO.Path]::Combine($reportRoot, 'qa-results.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Equal 'Mid-QA failure still writes all reports' $true $artifactsExist
    Test-Equal 'Failed report is not marked passed' 'failed' ([string]$reportData.status)
} finally {
    if ([System.IO.Directory]::Exists($reportRoot)) { [System.IO.Directory]::Delete($reportRoot, $true) }
}

$results | Format-Table -AutoSize
$hostIsPowerShell51 = $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
[pscustomobject]@{ Name='Windows PowerShell 5.1 host'; Passed=$hostIsPowerShell51; Details=$PSVersionTable.PSVersion.ToString() } | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -or -not $hostIsPowerShell51) { exit 1 }
