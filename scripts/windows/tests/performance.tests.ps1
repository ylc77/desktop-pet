[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$windowsRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..'))
. ([System.IO.Path]::Combine($windowsRoot, 'performance-common.ps1'))
$results = @()

function Add-Test([string]$Name, [object]$Expected, [object]$Actual) {
    $script:results += [pscustomobject]@{ Name=$Name; Passed=$Expected -eq $Actual; Details="expected=$Expected; actual=$Actual" }
}

function Test-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action; return $false } catch { return $_.Exception.Message -match $Pattern }
}

function New-ProcessRecord(
    [int]$ProcessId,
    [int]$ParentProcessId,
    [string]$Name,
    [int64]$WorkingSet,
    [int64]$PrivateMemory,
    [int64]$CpuTime100ns
) {
    [pscustomobject]@{
        ProcessId=$ProcessId; ParentProcessId=$ParentProcessId; Name=$Name; CreationDate="created-$ProcessId"
        KernelModeTime=[int64]($CpuTime100ns / 2); UserModeTime=[int64]($CpuTime100ns / 2)
        WorkingSetSize=$WorkingSet; PrivatePageCount=$PrivateMemory; HandleCount=($ProcessId % 10 + 1); ThreadCount=($ProcessId % 5 + 1)
    }
}

function New-AggregateRow(
    [string]$RunId,
    [int]$Index,
    [string]$Timestamp,
    [double]$Elapsed,
    [int]$Interval = 10
) {
    [pscustomobject]@{
        RecordType='Aggregate'; RunId=$RunId; SampleIndex=$Index; TimestampUtc=$Timestamp; ElapsedSeconds=$Elapsed; IntervalSeconds=$Interval
        RootProcessCount=1; WebView2ProcessCount=2; ProcessCount=3; CPUPercent=$(if($Index -eq 0){''}else{1.5})
        WorkingSetBytes=(1000 + $Index); PrivateMemoryBytes=(800 + $Index); Handles=(20 + $Index); Threads=(10 + $Index)
    }
}

$records = @(
    (New-ProcessRecord 100 1 'desktop_pet.exe' 1000 800 10000000),
    (New-ProcessRecord 101 100 'msedgewebview2.exe' 2000 1500 20000000),
    (New-ProcessRecord 102 101 'msedgewebview2.exe' 3000 2500 30000000),
    (New-ProcessRecord 103 100 'crashpad_handler.exe' 500 400 5000000),
    (New-ProcessRecord 999 1 'msedgewebview2.exe' 9000 9000 90000000)
)
$tree = @(Select-DeskPetPerformanceProcessTree -ProcessRecords $records -RootProcessName 'desktop_pet')
Add-Test 'Recursive tree includes root and every descendant' 4 $tree.Count
Add-Test 'Unrelated WebView2 process is excluded' 0 @($tree | Where-Object ProcessId -eq 999).Count
Add-Test 'Recursive WebView2 descendants are counted' 2 @($tree | Where-Object IsWebView2).Count

$first = New-DeskPetPerformanceSample -ProcessTree $tree -RunId 'run-one' -SampleIndex 0 -TimestampUtc ([DateTime]'2026-01-01T00:00:00Z') -ElapsedSeconds 0 -IntervalSeconds 10 -ProcessorCount 2
Add-Test 'Aggregate contains one row for complete tree' 4 $first.Aggregate.ProcessCount
Add-Test 'Working set is aggregated over complete tree' 6500 $first.Aggregate.WorkingSetBytes
Add-Test 'Per-process detail is preserved separately' 4 $first.Details.Count
$secondRecords = @(
    (New-ProcessRecord 100 1 'desktop_pet.exe' 1100 850 30000000),
    (New-ProcessRecord 101 100 'msedgewebview2.exe' 2100 1550 40000000),
    (New-ProcessRecord 102 101 'msedgewebview2.exe' 3100 2550 50000000),
    (New-ProcessRecord 103 100 'crashpad_handler.exe' 600 450 25000000)
)
$secondTree = @(Select-DeskPetPerformanceProcessTree -ProcessRecords $secondRecords -RootProcessName 'desktop_pet')
$second = New-DeskPetPerformanceSample -ProcessTree $secondTree -RunId 'run-one' -SampleIndex 1 -TimestampUtc ([DateTime]'2026-01-01T00:00:10Z') -ElapsedSeconds 10 -IntervalSeconds 10 -PreviousCpuTimes $first.CpuTimes -PreviousTimestampUtc $first.TimestampUtc -ProcessorCount 2
Add-Test 'Tree CPU is aggregated from per-process deltas' 40 $second.Aggregate.CPUPercent

$validRows = @(
    (New-AggregateRow 'run-one' 0 '2026-01-01T00:00:00Z' 0),
    (New-AggregateRow 'run-one' 1 '2026-01-01T00:00:10Z' 10),
    (New-AggregateRow 'run-one' 2 '2026-01-01T00:00:20Z' 20)
)
$validation = Assert-PerformanceAggregateRows -Rows $validRows
Add-Test 'One monotonic RunId is accepted' 'run-one' $validation.RunId
$mixedRows = @($validRows[0], (New-AggregateRow 'run-two' 1 '2026-01-01T00:00:10Z' 10))
Add-Test 'Mixed RunId is rejected' $true (Test-Throws { Assert-PerformanceAggregateRows -Rows $mixedRows } 'mixed RunId')
$nonMonotonicRows = @($validRows[0], (New-AggregateRow 'run-one' 1 '2026-01-01T00:00:00Z' 10))
Add-Test 'Non-monotonic timestamps are rejected' $true (Test-Throws { Assert-PerformanceAggregateRows -Rows $nonMonotonicRows } 'not strictly increasing')
$largeGapRows = @($validRows[0], (New-AggregateRow 'run-one' 1 '2026-01-01T00:00:40Z' 40))
Add-Test 'Abnormally large sample gaps are rejected' $true (Test-Throws { Assert-PerformanceAggregateRows -Rows $largeGapRows } 'abnormal sample gap')
$smallGapRows = @($validRows[0], (New-AggregateRow 'run-one' 1 '2026-01-01T00:00:01Z' 1))
Add-Test 'Abnormally small sample gaps are rejected' $true (Test-Throws { Assert-PerformanceAggregateRows -Rows $smallGapRows } 'abnormal sample gap')

$callerBase = 'F:\STAGE\desk pet'
$expectedCallerPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($callerBase, 'qa-results', 'performance.csv'))
Add-Test 'Performance output resolves against caller directory' $expectedCallerPath (Resolve-CallerPath -Path '.\qa-results\performance.csv' -BaseDirectory $callerBase)
$unicodeBrand = -join @([char]0x4E03,[char]0x9171,[char]0x684C,[char]0x5BA0)
$unicodeResultDirectory = (-join @([char]0x6027,[char]0x80FD)) + ' ' + (-join @([char]0x7ED3,[char]0x679C))
$unicodeFileName = (-join @([char]0x805A,[char]0x5408)) + '.csv'
$unicodeCallerBase = "F:\STAGE\$unicodeBrand test"
$unicodeRelativePath = [System.IO.Path]::Combine('.', $unicodeResultDirectory, $unicodeFileName)
$unicodeExpectedPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($unicodeCallerBase, $unicodeResultDirectory, $unicodeFileName))
Add-Test 'Performance output supports Chinese paths with spaces' $unicodeExpectedPath (Resolve-CallerPath -Path $unicodeRelativePath -BaseDirectory $unicodeCallerBase)
$exists = { param($Path) $Path.EndsWith('aggregate.csv', [StringComparison]::OrdinalIgnoreCase) }
Add-Test 'Existing output is rejected by default' $true (Test-Throws { Assert-PerformanceOutputTargets -AggregatePath 'C:\temp\aggregate.csv' -DetailPath 'C:\temp\details.csv' -FileExists $exists } 'Use -Overwrite')
Assert-PerformanceOutputTargets -AggregatePath 'C:\temp\aggregate.csv' -DetailPath 'C:\temp\details.csv' -Overwrite -FileExists $exists
Add-Test 'Explicit overwrite permits an existing target' $true $true

$runQaText = Get-Content -LiteralPath ([System.IO.Path]::Combine($windowsRoot, 'run-qa-suite.ps1')) -Raw -Encoding UTF8
$startIndex = $runQaText.IndexOf('-Phase StartAndVerify', [StringComparison]::Ordinal)
$captureIndex = $runQaText.IndexOf('monitor-process.ps1', $startIndex, [StringComparison]::Ordinal)
$exitIndex = $runQaText.IndexOf('-Phase WaitForNormalExit', $captureIndex, [StringComparison]::Ordinal)
Add-Test 'QA keeps app alive through performance capture' $true ($startIndex -ge 0 -and $captureIndex -gt $startIndex -and $exitIndex -gt $captureIndex)

$results | Format-Table -AutoSize
$hostIsPowerShell51 = $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
[pscustomobject]@{ Name='Windows PowerShell 5.1 host'; Passed=$hostIsPowerShell51; Details=$PSVersionTable.PSVersion.ToString() } | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -or -not $hostIsPowerShell51) { exit 1 }
