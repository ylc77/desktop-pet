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

$programFilesPath = [System.IO.Path]::Combine('C:\Program Files', $script:ProductName)
$chinesePrefix = -join @([char]0x684C,[char]0x5BA0,' ',[char]0x6D4B,[char]0x8BD5)
$chinesePath = [System.IO.Path]::Combine('C:\' + $chinesePrefix, $script:ProductName)
Test-Equal 'Valid Program Files path' ([System.IO.Path]::Combine($programFilesPath, $script:ExecutableName)) (Join-NativeFileSystemPath $programFilesPath $script:ExecutableName)
Test-Equal 'Trailing backslash' ([System.IO.Path]::Combine($programFilesPath, $script:ExecutableName)) (Join-NativeFileSystemPath ($programFilesPath + '\') $script:ExecutableName)
Test-Equal 'Quoted path' ([System.IO.Path]::Combine($programFilesPath, $script:ExecutableName)) (Join-NativeFileSystemPath ('"' + $programFilesPath + '"') $script:ExecutableName)
Test-Equal 'Chinese and spaces' ([System.IO.Path]::Combine($chinesePath, $script:ExecutableName)) (Join-NativeFileSystemPath $chinesePath $script:ExecutableName)
Test-Throws 'Empty InstallLocation' { Join-NativeFileSystemPath '' $script:ExecutableName } 'InstallLocation is empty'
Test-Throws 'Relative InstallLocation' { Join-NativeFileSystemPath '.\Relative Product' $script:ExecutableName } 'not an absolute path'

$validDirectory = [System.IO.Path]::Combine('C:\Valid', $script:ProductName)
$expectedVersion = Get-DeskPetReleaseVersion -RepositoryRoot $script:RepositoryRoot
$validExecutable = [System.IO.Path]::Combine($validDirectory, $script:ExecutableName)
$directoryExists = { param($Path) $Path -eq $validDirectory }.GetNewClosure()
$fileExists = { param($Path) $Path -eq $validExecutable }.GetNewClosure()
$records = @(
    [pscustomobject]@{ DisplayName=$script:ProductName; DisplayVersion=$expectedVersion; InstallLocation='Z:\Old Product'; PSPath='Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\Old' },
    [pscustomobject]@{ DisplayName=$script:ProductName; DisplayVersion=$expectedVersion; InstallLocation=($validDirectory + '\'); PSPath='Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER\Valid' }
)
$selection = Select-DeskPetInstallRecord -Records $records -ExpectedVersion $expectedVersion -DirectoryExists $directoryExists -FileExists $fileExists
Test-Equal 'Second valid record selected after stale first record' $validExecutable $selection.ExecutablePath
Test-Equal 'Unavailable drive record marked unusable' $false $selection.Evaluations[0].Usable
Test-Equal 'Current-user record preferred' $true $selection.Evaluation.CurrentUser

$missingExecutable = Select-DeskPetInstallRecord -Records @([pscustomobject]@{
    DisplayName=$script:ProductName; DisplayVersion=$expectedVersion; InstallLocation='C:\Installed'; PSPath='Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER\MissingExe'
}) -ExpectedVersion $expectedVersion -DirectoryExists { $true } -FileExists { $false }
Test-Equal 'Installed record without main executable fails selection' $null $missingExecutable.SelectedRecord

$isolatedResult = & {
    function Get-PSDrive { return $null }
    if ($null -ne (Get-PSDrive -Name C -ErrorAction SilentlyContinue)) { throw 'The isolated PSDrive simulation failed.' }
    Join-NativeFileSystemPath $programFilesPath $script:ExecutableName
}
Test-Equal 'Native combine is independent of a C PSDrive' ([System.IO.Path]::Combine($programFilesPath, $script:ExecutableName)) ([string]$isolatedResult)

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
