[CmdletBinding()]
param(
    [string]$ProcessName,
    [ValidateRange(1, 86400)][int]$IntervalSeconds = 10,
    [ValidateRange(1, 10080)][int]$DurationMinutes = 60,
    [ValidateRange(0, 86400)][int]$DurationSeconds = 0,
    [string]$OutputPath,
    [string]$DetailOutputPath,
    [switch]$Overwrite
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\performance-common.ps1"

if ([string]::IsNullOrWhiteSpace($ProcessName)) { $ProcessName = $script:ProcessName }
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = [System.IO.Path]::Combine($InvocationDirectory, 'temp', 'performance-samples.csv')
}
$aggregatePath = Resolve-CallerPath -Path $OutputPath -BaseDirectory $InvocationDirectory
if ([string]::IsNullOrWhiteSpace($DetailOutputPath)) {
    $detailName = [System.IO.Path]::GetFileNameWithoutExtension($aggregatePath) + '-processes.csv'
    $DetailOutputPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($aggregatePath), $detailName)
}
$detailPath = Resolve-CallerPath -Path $DetailOutputPath -BaseDirectory $InvocationDirectory
Assert-PerformanceOutputTargets -AggregatePath $aggregatePath -DetailPath $detailPath -Overwrite:$Overwrite

foreach ($path in @($aggregatePath, $detailPath)) {
    $parent = [System.IO.Path]::GetDirectoryName($path)
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
    if ($Overwrite -and [System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) }
}

$runId = [guid]::NewGuid().ToString('D')
$duration = if ($DurationSeconds -gt 0) { [double]$DurationSeconds } else { [double]$DurationMinutes * 60 }
if ($duration -lt $IntervalSeconds) { throw 'Performance duration must be at least one complete sampling interval.' }
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$previousCpuTimes = @{}
$previousTimestampUtc = $null
$sampleIndex = 0
Write-Host "Performance run: $runId"
Write-Host "Aggregate CSV: $aggregatePath"
Write-Host "Process detail CSV: $detailPath"

while ($true) {
    $processRecords = @(Get-CimInstance Win32_Process)
    $tree = @(Select-DeskPetPerformanceProcessTree -ProcessRecords $processRecords -RootProcessName $ProcessName)
    if (-not $tree.Count) { throw "Process '$ProcessName' is not running or its process tree could not be captured." }
    $timestampUtc = [DateTime]::UtcNow
    $sample = New-DeskPetPerformanceSample -ProcessTree $tree -RunId $runId -SampleIndex $sampleIndex `
        -TimestampUtc $timestampUtc -ElapsedSeconds $stopwatch.Elapsed.TotalSeconds -IntervalSeconds $IntervalSeconds `
        -PreviousCpuTimes $previousCpuTimes -PreviousTimestampUtc $previousTimestampUtc
    $append = $sampleIndex -gt 0
    $sample.Aggregate | Export-Csv -LiteralPath $aggregatePath -NoTypeInformation -Append:$append -Encoding UTF8
    $sample.Details | Export-Csv -LiteralPath $detailPath -NoTypeInformation -Append:$append -Encoding UTF8
    $previousCpuTimes = $sample.CpuTimes
    $previousTimestampUtc = $sample.TimestampUtc
    $sampleIndex++
    if ($stopwatch.Elapsed.TotalSeconds -ge $duration) { break }
    Start-Sleep -Seconds $IntervalSeconds
}
$stopwatch.Stop()
Write-Host "Performance samples written: runId=$runId; samples=$sampleIndex; elapsedSeconds=$([Math]::Round($stopwatch.Elapsed.TotalSeconds, 3))"
