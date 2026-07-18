[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\common.ps1"

$results = @()
function Add-Test([string]$Name, [bool]$Passed, [string]$Details) {
    $script:results += [pscustomobject]@{ Name=$Name; Passed=$Passed; Details=$Details }
}
function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
function Invoke-SmokeChild([string]$Command) {
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Command))
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "$PSHOME\powershell.exe"
    $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode=$process.ExitCode; Output=$standardOutput; Error=$standardError }
}

$root = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'qijiang-startup-smoke-tests-' + [Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($root)
try {
    $smokeScript = [System.IO.Path]::Combine($script:RepositoryRoot, 'scripts', 'windows', 'startup-smoke-test.ps1')
    $slowFixture = [System.IO.Path]::Combine($root, 'slow fixture.ps1')
    $earlyExitFixture = [System.IO.Path]::Combine($root, 'early exit.ps1')
    $passReport = [System.IO.Path]::Combine($root, 'pass report.json')
    $failureReport = [System.IO.Path]::Combine($root, 'failure report.json')
    Write-Utf8NoBom $slowFixture 'Start-Sleep -Seconds 5'
    Write-Utf8NoBom $earlyExitFixture 'exit 101'

    $passCommand = "& '$($smokeScript.Replace("'", "''"))' -ExecutablePath '$($PSHOME.Replace("'", "''"))\powershell.exe' -Arguments '-NoProfile -ExecutionPolicy Bypass -File `"$($slowFixture.Replace("'", "''"))`"' -MinimumUptimeSeconds 1 -AllowNoWindow -AllowPreexistingProcess -ResultPath '$($passReport.Replace("'", "''"))'"
    $passInvocation = Invoke-SmokeChild $passCommand
    $passExitCode = $passInvocation.ExitCode
    $passState = Get-Content -LiteralPath $passReport -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Test 'A process surviving the required interval passes' ($passExitCode -eq 0 -and $passState.status -eq 'passed' -and $passState.survived) "exit=$passExitCode; status=$($passState.status)"
    Add-Test 'Successful smoke cleanup leaves no launched process' (-not [bool]$passState.processRemainingAfterCleanup) "remaining=$($passState.processRemainingAfterCleanup)"

    $failureCommand = "& '$($smokeScript.Replace("'", "''"))' -ExecutablePath '$($PSHOME.Replace("'", "''"))\powershell.exe' -Arguments '-NoProfile -ExecutionPolicy Bypass -File `"$($earlyExitFixture.Replace("'", "''"))`"' -MinimumUptimeSeconds 1 -AllowNoWindow -AllowPreexistingProcess -ResultPath '$($failureReport.Replace("'", "''"))'"
    $failureInvocation = Invoke-SmokeChild $failureCommand
    $failureExitCode = $failureInvocation.ExitCode
    $failureState = Get-Content -LiteralPath $failureReport -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Test 'An early ExitCode 101 fails startup QA' ($failureExitCode -ne 0 -and -not $failureState.survived -and [int]$failureState.exitCode -eq 101) "exit=$failureExitCode; appExit=$($failureState.exitCode)"
    Add-Test 'Startup failure still writes a complete report' ([System.IO.File]::Exists($failureReport) -and $failureState.status -eq 'failed' -and -not [string]::IsNullOrWhiteSpace([string]$failureState.failureMessage)) "status=$($failureState.status)"

    $dispatcher = [System.IO.File]::ReadAllText(([System.IO.Path]::Combine($script:RepositoryRoot, 'scripts', 'windows', 'run-qa-suite.ps1')), [System.Text.Encoding]::UTF8)
    Add-Test 'Safe QA runs the release startup smoke for ten seconds' ($dispatcher -match "Release startup smoke test" -and $dispatcher -match 'MinimumUptimeSeconds 10') 'Inspected Safe QA dispatcher.'
} finally {
    if ([System.IO.Directory]::Exists($root)) { [System.IO.Directory]::Delete($root, $true) }
}

$results | Format-Table -AutoSize
$hostIsPowerShell51 = $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
[pscustomobject]@{ Name='Windows PowerShell 5.1 host'; Passed=$hostIsPowerShell51; Details=$PSVersionTable.PSVersion.ToString() } | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -or -not $hostIsPowerShell51) { exit 1 }
