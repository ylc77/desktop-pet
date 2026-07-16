[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [string]$OutputPath,
    [string]$JsonOutputPath
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\performance-common.ps1"

$resolvedInputPath = Resolve-CallerPath -Path $InputPath -BaseDirectory $InvocationDirectory
if (-not [System.IO.File]::Exists($resolvedInputPath)) { throw "Performance CSV not found: $resolvedInputPath" }
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Resolve-CallerPath -Path $OutputPath -BaseDirectory $InvocationDirectory }
if (-not [string]::IsNullOrWhiteSpace($JsonOutputPath)) { $JsonOutputPath = Resolve-CallerPath -Path $JsonOutputPath -BaseDirectory $InvocationDirectory }
$rows = @(Import-Csv -LiteralPath $resolvedInputPath)
$validation = Assert-PerformanceAggregateRows -Rows $rows

function Measure-Field([string]$Name) {
    $values = @($rows | ForEach-Object {
        $value = [string](Get-PerformancePropertyValue -InputObject $_ -Name $Name -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($value)) { ConvertTo-PerformanceNumber -Value $value -FieldName $Name }
    })
    if (-not $values.Count) { return $null }
    [ordered]@{
        initial=$values[0]
        minimum=($values | Measure-Object -Minimum).Minimum
        average=[math]::Round(($values | Measure-Object -Average).Average, 3)
        maximum=($values | Measure-Object -Maximum).Maximum
        final=$values[-1]
        delta=$values[-1] - $values[0]
    }
}

$first = [DateTimeOffset]::Parse([string]$rows[0].TimestampUtc, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
$last = [DateTimeOffset]::Parse([string]$rows[-1].TimestampUtc, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
$durationHours = [math]::Round(($last - $first).TotalHours, 4)
$summary = [ordered]@{
    runId = $validation.RunId
    samples = $rows.Count
    source = [System.IO.Path]::GetFileName($resolvedInputPath)
    firstSampleUtc = $rows[0].TimestampUtc
    lastSampleUtc = $rows[-1].TimestampUtc
    intervalSeconds = $validation.IntervalSeconds
    minimumAllowedGapSeconds = $validation.MinimumAllowedGapSeconds
    maximumObservedGapSeconds = $validation.MaximumObservedGapSeconds
    maximumAllowedGapSeconds = $validation.MaximumAllowedGapSeconds
    durationHours = $durationHours
    durationCategory = $(if ($durationHours -ge 7.9) { 'eight_hour_duration_captured' } else { 'captured_interval_only' })
    assessment = 'requires_manual_review'
    processCount = Measure-Field 'ProcessCount'
    rootProcessCount = Measure-Field 'RootProcessCount'
    webView2ProcessCount = Measure-Field 'WebView2ProcessCount'
    cpuPercent = Measure-Field 'CPUPercent'
    workingSetBytes = Measure-Field 'WorkingSetBytes'
    privateMemoryBytes = Measure-Field 'PrivateMemoryBytes'
    handles = Measure-Field 'Handles'
    threads = Measure-Field 'Threads'
}
$cpuMaximum = if ($null -eq $summary.cpuPercent) { '<unavailable>' } else { "$($summary.cpuPercent.maximum)%" }
$lines = @(
    '# Performance summary', '',
    "- Run ID: $($summary.runId)",
    "- Samples: $($summary.samples)",
    "- Range: $($summary.firstSampleUtc) to $($summary.lastSampleUtc)",
    "- Duration: $durationHours hours",
    "- Duration category: $($summary.durationCategory)",
    "- Interval: $($summary.intervalSeconds) seconds; maximum observed gap: $($summary.maximumObservedGapSeconds) seconds",
    "- Process tree count: initial=$($summary.processCount.initial), peak=$($summary.processCount.maximum), final=$($summary.processCount.final)",
    "- WebView2 count: initial=$($summary.webView2ProcessCount.initial), peak=$($summary.webView2ProcessCount.maximum), final=$($summary.webView2ProcessCount.final)",
    "- CPU maximum: $cpuMaximum",
    "- Working set: initial=$($summary.workingSetBytes.initial), peak=$($summary.workingSetBytes.maximum), final=$($summary.workingSetBytes.final), delta=$($summary.workingSetBytes.delta) bytes",
    "- Private memory: initial=$($summary.privateMemoryBytes.initial), peak=$($summary.privateMemoryBytes.maximum), final=$($summary.privateMemoryBytes.final), delta=$($summary.privateMemoryBytes.delta) bytes",
    "- Handles: initial=$($summary.handles.initial), peak=$($summary.handles.maximum), final=$($summary.handles.final), delta=$($summary.handles.delta)",
    "- Threads: initial=$($summary.threads.initial), peak=$($summary.threads.maximum), final=$($summary.threads.final), delta=$($summary.threads.delta)", '',
    '> Capturing eight hours does not by itself mark stability as passed. Review trends, interaction notes, responsiveness, log rotation, and clean process exit.'
)
$text = $lines -join [Environment]::NewLine
foreach ($path in @($OutputPath, $JsonOutputPath)) {
    if ([string]::IsNullOrWhiteSpace($path)) { continue }
    $parent = [System.IO.Path]::GetDirectoryName($path)
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
}
if ($OutputPath) { $text | Set-Content -Encoding UTF8 -LiteralPath $OutputPath }
if ($JsonOutputPath) { $summary | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $JsonOutputPath }
$text
