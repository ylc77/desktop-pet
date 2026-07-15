[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$rows = @(Import-Csv -LiteralPath $InputPath)
if (-not $rows.Count) { throw 'Performance CSV contains no samples.' }
function Measure-Field([string]$Name) {
    $values = @($rows | ForEach-Object { if ($_.$Name -ne '') { [double]$_.$Name } })
    [ordered]@{ minimum = ($values | Measure-Object -Minimum).Minimum; average = [math]::Round(($values | Measure-Object -Average).Average, 3); maximum = ($values | Measure-Object -Maximum).Maximum }
}
$summary = [ordered]@{
    samples = $rows.Count
    firstSampleUtc = $rows[0].TimestampUtc
    lastSampleUtc = $rows[-1].TimestampUtc
    cpuPercent = Measure-Field 'CPUPercent'
    workingSetBytes = Measure-Field 'WorkingSetBytes'
    privateMemoryBytes = Measure-Field 'PrivateMemoryBytes'
    handles = Measure-Field 'Handles'
    threads = Measure-Field 'Threads'
}
$lines = @('# Performance summary', '', "- Samples: $($summary.samples)", "- Range: $($summary.firstSampleUtc) to $($summary.lastSampleUtc)", "- CPU maximum: $($summary.cpuPercent.maximum)%", "- Working set maximum: $($summary.workingSetBytes.maximum) bytes", "- Private memory maximum: $($summary.privateMemoryBytes.maximum) bytes", "- Handles maximum: $($summary.handles.maximum)", "- Threads maximum: $($summary.threads.maximum)", '', '> This summary reports the captured interval only. It is not an 8-hour pass unless the CSV spans 8 hours.')
$text = $lines -join [Environment]::NewLine
if ($OutputPath) { $text | Set-Content -Encoding UTF8 -LiteralPath $OutputPath }
$text
