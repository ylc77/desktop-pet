[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [string]$Arguments = '',
    [ValidateRange(1, 120)][int]$MinimumUptimeSeconds = 10,
    [string]$ExpectedWindowTitle,
    [switch]$AllowNoWindow,
    [switch]$AllowPreexistingProcess,
    [string]$ResultPath
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

$executable = Resolve-CallerPath -Path $ExecutablePath -BaseDirectory $InvocationDirectory
Assert-FileExists $executable 'Startup smoke executable'
if ([string]::IsNullOrWhiteSpace($ExpectedWindowTitle)) { $ExpectedWindowTitle = $script:ProductName }
if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    $ResultPath = Resolve-CallerPath -Path $ResultPath -BaseDirectory $InvocationDirectory
}

$profileRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'qijiang-startup-smoke-' + [Guid]::NewGuid().ToString('N'))
$localData = [System.IO.Path]::Combine($profileRoot, 'LocalAppData')
$roamingData = [System.IO.Path]::Combine($profileRoot, 'AppData')
$temporaryData = [System.IO.Path]::Combine($profileRoot, 'Temp')
[void][System.IO.Directory]::CreateDirectory($localData)
[void][System.IO.Directory]::CreateDirectory($roamingData)
[void][System.IO.Directory]::CreateDirectory($temporaryData)

$result = [ordered]@{
    schemaVersion=1
    executable=[System.IO.Path]::GetFileName($executable)
    requiredUptimeSeconds=$MinimumUptimeSeconds
    observedUptimeMilliseconds=0
    survived=$false
    windowObserved=$false
    observedWindowTitle=$null
    windowTitleMatched=$false
    expectedWindowTitle=$ExpectedWindowTitle
    exitCode=$null
    processRemainingAfterCleanup=$false
    status='failed'
}
$process = $null
$exitCode = 2
try {
    $processName = [System.IO.Path]::GetFileNameWithoutExtension($executable)
    if (-not $AllowPreexistingProcess -and (Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
        throw "Startup smoke test requires no pre-existing '$processName' process."
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executable
    $startInfo.Arguments = $Arguments
    $startInfo.WorkingDirectory = [System.IO.Path]::GetDirectoryName($executable)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    # On current Windows builds, Windows PowerShell 5.1 can expose
    # ProcessStartInfo.EnvironmentVariables as null under StrictMode. Apply
    # the four child-only overrides to this process just long enough for the
    # child to inherit them, then restore the QA host immediately.
    $environmentOverrides = @{
        LOCALAPPDATA = $localData
        APPDATA = $roamingData
        TEMP = $temporaryData
        TMP = $temporaryData
    }
    $environmentBackup = @{}
    try {
        foreach ($name in $environmentOverrides.Keys) {
            $environmentBackup[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $environmentOverrides[$name], 'Process')
        }
        if (-not $process.Start()) { throw 'Windows did not start the application process.' }
    } finally {
        foreach ($name in $environmentBackup.Keys) {
            [Environment]::SetEnvironmentVariable($name, $environmentBackup[$name], 'Process')
        }
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $deadline = [DateTime]::UtcNow.AddSeconds($MinimumUptimeSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()
        if ($process.HasExited) { break }
        $nativeProcess = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
        if ($nativeProcess) {
            $nativeProcess.Refresh()
            if ($nativeProcess.MainWindowHandle -ne [IntPtr]::Zero) {
                $result.windowObserved = $true
                $result.observedWindowTitle = $nativeProcess.MainWindowTitle
                $result.windowTitleMatched = [string]::IsNullOrWhiteSpace($ExpectedWindowTitle) -or
                    $nativeProcess.MainWindowTitle -eq $ExpectedWindowTitle
            }
        }
        Start-Sleep -Milliseconds 250
    }
    $stopwatch.Stop()
    $result.observedUptimeMilliseconds = [int64]$stopwatch.ElapsedMilliseconds
    $process.Refresh()
    $result.survived = -not $process.HasExited
    if ($process.HasExited) { $result.exitCode = $process.ExitCode }

    if (-not $result.survived) {
        throw "Application exited before the required $MinimumUptimeSeconds seconds (exitCode=$($result.exitCode))."
    }
    if (-not $AllowNoWindow -and -not $result.windowObserved) {
        throw 'Application stayed alive, but no expected top-level window was observed.'
    }

    $result.status = 'passed'
    $exitCode = 0
} catch {
    $result['failureCategory'] = $_.Exception.GetType().Name
    $result['failureMessage'] = $_.Exception.Message
} finally {
    if ($null -ne $process) {
        try {
            $process.Refresh()
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                [void]$process.WaitForExit(5000)
            }
            $result.processRemainingAfterCleanup = [bool](Get-Process -Id $process.Id -ErrorAction SilentlyContinue)
        } catch {
            $result.processRemainingAfterCleanup = $true
        }
        $process.Dispose()
    }
    if ($result.processRemainingAfterCleanup) {
        $result.status = 'failed'
        $exitCode = 2
    }
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        $parent = [System.IO.Path]::GetDirectoryName($ResultPath)
        if (-not [string]::IsNullOrWhiteSpace($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
        $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    }
    if ([System.IO.Directory]::Exists($profileRoot)) {
        try { [System.IO.Directory]::Delete($profileRoot, $true) } catch { }
    }
}

$result | ConvertTo-Json -Depth 6
exit $exitCode
