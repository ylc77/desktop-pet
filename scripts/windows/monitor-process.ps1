[CmdletBinding()]
param(
    [string]$ProcessName,
    [ValidateRange(1, 86400)][int]$IntervalSeconds = 10,
    [ValidateRange(1, 10080)][int]$DurationMinutes = 60,
    [ValidateRange(0, 86400)][int]$DurationSeconds = 0,
    [string]$OutputPath = (Join-Path $PWD 'temp\performance-samples.csv')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
if ([string]::IsNullOrWhiteSpace($ProcessName)) { $ProcessName = $script:ProcessName }
$parent = Split-Path -Parent $OutputPath
if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
$deadline = if ($DurationSeconds -gt 0) { [DateTime]::UtcNow.AddSeconds($DurationSeconds) } else { [DateTime]::UtcNow.AddMinutes($DurationMinutes) }
$previous = @{}
while ([DateTime]::UtcNow -lt $deadline) {
    $processes = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) { Write-Error "Process '$ProcessName' is not running."; exit 2 }
    foreach ($process in $processes) {
        $now = [DateTime]::UtcNow
        $cpuPercent = $null
        if ($previous.ContainsKey($process.Id)) {
            $sample = $previous[$process.Id]
            $elapsed = ($now - $sample.Time).TotalSeconds
            if ($elapsed -gt 0) { $cpuPercent = [math]::Round((($process.CPU - $sample.Cpu) / $elapsed / [Environment]::ProcessorCount) * 100, 3) }
        }
        $previous[$process.Id] = @{ Time = $now; Cpu = $process.CPU }
        [pscustomobject]@{
            TimestampUtc = $now.ToString('o'); PID = $process.Id; CPUPercent = $cpuPercent
            WorkingSetBytes = $process.WorkingSet64; PrivateMemoryBytes = $process.PrivateMemorySize64
            Handles = $process.HandleCount; Threads = $process.Threads.Count
        } | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Append -Encoding utf8
    }
    Start-Sleep -Seconds $IntervalSeconds
}
Write-Host "Performance samples written to $OutputPath"
