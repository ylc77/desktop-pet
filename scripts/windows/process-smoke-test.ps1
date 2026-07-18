[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [ValidateSet('Full','StartAndVerify','WaitForNormalExit')][string]$Phase = 'Full',
    [ValidateRange(10, 120)][int]$StartupSeconds = 10,
    [int]$ManualExitTimeoutSeconds = 30,
    [switch]$AllowForceCleanup
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$executable = Resolve-CallerPath -Path $ExecutablePath -BaseDirectory $InvocationDirectory
Assert-FileExists $executable 'Application executable'

if ($Phase -in @('Full','StartAndVerify')) {
    if (Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue) { throw 'A desk pet process is already running.' }
    if (-not $PSCmdlet.ShouldProcess($executable, 'Launch twice to verify single-instance behavior')) { exit 0 }
    $firstLaunch = Start-Process -FilePath $executable -WindowStyle Hidden -PassThru
    $startupDeadline = [DateTime]::UtcNow.AddSeconds($StartupSeconds)
    while ([DateTime]::UtcNow -lt $startupDeadline) {
        $firstLaunch.Refresh()
        if ($firstLaunch.HasExited) {
            Write-SmokeResult 'First launch survives startup interval' $false "exitCode=$($firstLaunch.ExitCode); requiredSeconds=$StartupSeconds" | Format-Table -AutoSize
            exit 2
        }
        Start-Sleep -Milliseconds 250
    }
    Start-Process -FilePath $executable -WindowStyle Hidden
    Start-Sleep -Seconds 2
    $firstLaunch.Refresh()
    $instances = @(Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue)
    $singleInstance = -not $firstLaunch.HasExited -and $instances.Count -eq 1
    $windowTitleMatches = @($instances | Where-Object { $_.MainWindowTitle -eq $script:ProductName }).Count
    $startupResults = @(
        Write-SmokeResult 'First launch survives startup interval' (-not $firstLaunch.HasExited) "requiredSeconds=$StartupSeconds"
        Write-SmokeResult 'Single instance after second launch' $singleInstance "count=$($instances.Count)"
        Write-SmokeResult 'Window title matches DisplayName' ($windowTitleMatches -eq 1) "expected=$script:ProductName; matches=$windowTitleMatches"
    )
    $startupResults | Format-Table -AutoSize
    if (-not $singleInstance -or $windowTitleMatches -ne 1) {
        if ($AllowForceCleanup) { $instances | Stop-Process -Force }
        exit 2
    }
    if ($Phase -eq 'StartAndVerify') {
        Write-Host 'The verified application instance remains running for subsequent QA phases.'
        exit 0
    }
}

if ($Phase -in @('Full','WaitForNormalExit')) {
    $runningBeforeExit = @(Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue)
    if ($runningBeforeExit.Count -ne 1) {
        Write-SmokeResult 'One verified process exists before normal exit' $false "count=$($runningBeforeExit.Count)" | Format-Table -AutoSize
        exit 3
    }
    if (-not $PSCmdlet.ShouldProcess($script:ProductName, 'Wait for a manual normal exit from the tray or context menu')) { exit 0 }
    Write-Host "Exit the application normally from its tray or context menu within $ManualExitTimeoutSeconds seconds."
    $deadline = [DateTime]::UtcNow.AddSeconds($ManualExitTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline -and (Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 500 }
    $remaining = @(Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue)
    if ($remaining.Count -gt 0 -and $AllowForceCleanup) { $remaining | Stop-Process -Force }
    Write-SmokeResult 'Normal exit leaves no process' ($remaining.Count -eq 0) "remaining=$($remaining.Count)" | Format-Table -AutoSize
    if ($remaining.Count -gt 0) { exit 3 }
}
