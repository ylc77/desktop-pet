[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [string]$OutputPath,
    [string]$JsonOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$rows = @(Import-Csv -LiteralPath $InputPath)
if (-not $rows.Count) { throw 'Performance CSV contains no samples.' }
function Measure-Field([string]$Name) {
    $values = @($rows | ForEach-Object { if ($_.$Name -ne '') { [double]$_.$Name } })
    [ordered]@{
        initial=$values[0]; minimum=($values | Measure-Object -Minimum).Minimum
        average=[math]::Round(($values | Measure-Object -Average).Average, 3); maximum=($values | Measure-Object -Maximum).Maximum
        final=$values[-1]; delta=$values[-1] - $values[0]
    }
}
$first = [DateTime]::Parse([string]$rows[0].TimestampUtc).ToUniversalTime()
$last = [DateTime]::Parse([string]$rows[-1].TimestampUtc).ToUniversalTime()
$durationHours = [math]::Round(($last - $first).TotalHours, 4)
$summary = [ordered]@{
    samples = $rows.Count
    firstSampleUtc = $rows[0].TimestampUtc
    lastSampleUtc = $rows[-1].TimestampUtc
    durationHours = $durationHours
    durationCategory = $(if ($durationHours -ge 7.9) { 'eight_hour_duration_captured' } else { 'captured_interval_only' })
    assessment = 'requires_manual_review'
    cpuPercent = Measure-Field 'CPUPercent'
    workingSetBytes = Measure-Field 'WorkingSetBytes'
    privateMemoryBytes = Measure-Field 'PrivateMemoryBytes'
    handles = Measure-Field 'Handles'
    threads = Measure-Field 'Threads'
}
$lines = @('# Performance summary', '', "- Samples: $($summary.samples)", "- Range: $($summary.firstSampleUtc) to $($summary.lastSampleUtc)", "- Duration: $durationHours hours", "- Duration category: $($summary.durationCategory)", "- CPU maximum: $($summary.cpuPercent.maximum)%", "- Working set: initial=$($summary.workingSetBytes.initial), peak=$($summary.workingSetBytes.maximum), final=$($summary.workingSetBytes.final), delta=$($summary.workingSetBytes.delta) bytes", "- Private memory: initial=$($summary.privateMemoryBytes.initial), peak=$($summary.privateMemoryBytes.maximum), final=$($summary.privateMemoryBytes.final), delta=$($summary.privateMemoryBytes.delta) bytes", "- Handles: initial=$($summary.handles.initial), peak=$($summary.handles.maximum), final=$($summary.handles.final), delta=$($summary.handles.delta)", "- Threads: initial=$($summary.threads.initial), peak=$($summary.threads.maximum), final=$($summary.threads.final), delta=$($summary.threads.delta)", '', '> Capturing eight hours does not by itself mark stability as passed. Review trends, interaction notes, responsiveness, log rotation, and clean process exit.')
$text = $lines -join [Environment]::NewLine
if ($OutputPath) { $text | Set-Content -Encoding UTF8 -LiteralPath $OutputPath }
if ($JsonOutputPath) { $summary | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $JsonOutputPath }
$text
