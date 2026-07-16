Set-StrictMode -Version Latest

. "$PSScriptRoot\common.ps1"

function Get-PerformancePropertyValue {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$DefaultValue = $null
    )
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
    return $property.Value
}

function Select-DeskPetPerformanceProcessTree {
    param(
        [AllowEmptyCollection()][object[]]$ProcessRecords = @(),
        [string]$RootProcessName = $script:ProcessName
    )
    $normalizedRootName = [System.IO.Path]::GetFileNameWithoutExtension($RootProcessName)
    $recordsById = @{}
    $childrenByParentId = @{}
    foreach ($record in @($ProcessRecords)) {
        $processId = [int](Get-PerformancePropertyValue -InputObject $record -Name 'ProcessId' -DefaultValue 0)
        if ($processId -le 0) { continue }
        $recordsById[$processId] = $record
        $parentProcessId = [int](Get-PerformancePropertyValue -InputObject $record -Name 'ParentProcessId' -DefaultValue 0)
        if (-not $childrenByParentId.ContainsKey($parentProcessId)) { $childrenByParentId[$parentProcessId] = @() }
        $childrenByParentId[$parentProcessId] = @($childrenByParentId[$parentProcessId]) + $processId
    }

    $rootIds = @($recordsById.Keys | Where-Object {
        $name = [string](Get-PerformancePropertyValue -InputObject $recordsById[$_] -Name 'Name' -DefaultValue '')
        [System.IO.Path]::GetFileNameWithoutExtension($name).Equals($normalizedRootName, [StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object)
    $assigned = @{}
    $selected = @()
    foreach ($rootId in $rootIds) {
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue([pscustomobject]@{ ProcessId=[int]$rootId; Depth=0 })
        while ($queue.Count -gt 0) {
            $candidate = $queue.Dequeue()
            $processId = [int]$candidate.ProcessId
            if ($assigned.ContainsKey($processId) -or -not $recordsById.ContainsKey($processId)) { continue }
            $assigned[$processId] = $true
            $record = $recordsById[$processId]
            $name = [string](Get-PerformancePropertyValue -InputObject $record -Name 'Name' -DefaultValue '')
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($name)
            $selected += [pscustomobject]@{
                Record = $record
                RootProcessId = [int]$rootId
                ProcessId = $processId
                ParentProcessId = [int](Get-PerformancePropertyValue -InputObject $record -Name 'ParentProcessId' -DefaultValue 0)
                Name = $name
                Depth = [int]$candidate.Depth
                IsRoot = $processId -eq [int]$rootId
                IsWebView2 = $baseName.Equals('msedgewebview2', [StringComparison]::OrdinalIgnoreCase)
            }
            foreach ($childId in @($childrenByParentId[$processId] | Sort-Object)) {
                $queue.Enqueue([pscustomobject]@{ ProcessId=[int]$childId; Depth=([int]$candidate.Depth + 1) })
            }
        }
    }
    return @($selected | Sort-Object RootProcessId, Depth, ProcessId)
}

function New-DeskPetPerformanceSample {
    param(
        [Parameter(Mandatory)][object[]]$ProcessTree,
        [Parameter(Mandatory)][string]$RunId,
        [ValidateRange(0, 2147483647)][int]$SampleIndex,
        [Parameter(Mandatory)][DateTime]$TimestampUtc,
        [ValidateRange(0, 1.7976931348623157E+308)][double]$ElapsedSeconds,
        [ValidateRange(1, 86400)][int]$IntervalSeconds,
        [hashtable]$PreviousCpuTimes = @{},
        [Nullable[DateTime]]$PreviousTimestampUtc = $null,
        [ValidateRange(1, 65536)][int]$ProcessorCount = [Environment]::ProcessorCount
    )
    if (-not $ProcessTree.Count) { throw 'The desktop pet process tree is empty.' }
    $timestamp = $TimestampUtc.ToUniversalTime()
    $elapsedFromPrevious = if ($null -eq $PreviousTimestampUtc) { 0 } else { ($timestamp - ([DateTime]$PreviousTimestampUtc).ToUniversalTime()).TotalSeconds }
    $nextCpuTimes = @{}
    $details = @()
    foreach ($node in @($ProcessTree)) {
        $record = Get-PerformancePropertyValue -InputObject $node -Name 'Record'
        $processId = [int](Get-PerformancePropertyValue -InputObject $node -Name 'ProcessId' -DefaultValue 0)
        $creationDate = [string](Get-PerformancePropertyValue -InputObject $record -Name 'CreationDate' -DefaultValue '')
        $identity = '{0}|{1}' -f $processId, $creationDate
        $kernelTime = [double](Get-PerformancePropertyValue -InputObject $record -Name 'KernelModeTime' -DefaultValue 0)
        $userTime = [double](Get-PerformancePropertyValue -InputObject $record -Name 'UserModeTime' -DefaultValue 0)
        $cpuTime100ns = $kernelTime + $userTime
        $nextCpuTimes[$identity] = $cpuTime100ns
        $cpuPercent = $null
        if ($elapsedFromPrevious -gt 0 -and $PreviousCpuTimes.ContainsKey($identity)) {
            $cpuDelta100ns = [Math]::Max(0, $cpuTime100ns - [double]$PreviousCpuTimes[$identity])
            $cpuPercent = [Math]::Round((($cpuDelta100ns / 10000000) / $elapsedFromPrevious / $ProcessorCount) * 100, 3)
        }
        $details += [pscustomobject][ordered]@{
            RunId = $RunId
            SampleIndex = $SampleIndex
            TimestampUtc = $timestamp.ToString('o')
            RootProcessId = [int](Get-PerformancePropertyValue -InputObject $node -Name 'RootProcessId' -DefaultValue 0)
            PID = $processId
            ParentPID = [int](Get-PerformancePropertyValue -InputObject $node -Name 'ParentProcessId' -DefaultValue 0)
            Depth = [int](Get-PerformancePropertyValue -InputObject $node -Name 'Depth' -DefaultValue 0)
            Name = [string](Get-PerformancePropertyValue -InputObject $node -Name 'Name' -DefaultValue '')
            IsRoot = [bool](Get-PerformancePropertyValue -InputObject $node -Name 'IsRoot' -DefaultValue $false)
            IsWebView2 = [bool](Get-PerformancePropertyValue -InputObject $node -Name 'IsWebView2' -DefaultValue $false)
            CPUPercent = $cpuPercent
            TotalProcessorTimeSeconds = [Math]::Round($cpuTime100ns / 10000000, 6)
            WorkingSetBytes = [int64](Get-PerformancePropertyValue -InputObject $record -Name 'WorkingSetSize' -DefaultValue 0)
            PrivateMemoryBytes = [int64](Get-PerformancePropertyValue -InputObject $record -Name 'PrivatePageCount' -DefaultValue 0)
            Handles = [int64](Get-PerformancePropertyValue -InputObject $record -Name 'HandleCount' -DefaultValue 0)
            Threads = [int64](Get-PerformancePropertyValue -InputObject $record -Name 'ThreadCount' -DefaultValue 0)
        }
    }

    $cpuValues = @($details | Where-Object { $null -ne $_.CPUPercent } | ForEach-Object { [double]$_.CPUPercent })
    $aggregateCpu = if ($cpuValues.Count) { [Math]::Round([double](($cpuValues | Measure-Object -Sum).Sum), 3) } else { $null }
    $aggregate = [pscustomobject][ordered]@{
        RecordType = 'Aggregate'
        RunId = $RunId
        SampleIndex = $SampleIndex
        TimestampUtc = $timestamp.ToString('o')
        ElapsedSeconds = [Math]::Round($ElapsedSeconds, 3)
        IntervalSeconds = $IntervalSeconds
        RootProcessCount = @($details | Where-Object { $_.IsRoot }).Count
        WebView2ProcessCount = @($details | Where-Object { $_.IsWebView2 }).Count
        ProcessCount = $details.Count
        CPUPercent = $aggregateCpu
        TotalProcessorTimeSeconds = [Math]::Round([double](($details | Measure-Object -Property TotalProcessorTimeSeconds -Sum).Sum), 6)
        WorkingSetBytes = [int64](($details | Measure-Object -Property WorkingSetBytes -Sum).Sum)
        PrivateMemoryBytes = [int64](($details | Measure-Object -Property PrivateMemoryBytes -Sum).Sum)
        Handles = [int64](($details | Measure-Object -Property Handles -Sum).Sum)
        Threads = [int64](($details | Measure-Object -Property Threads -Sum).Sum)
    }
    [pscustomobject]@{ Aggregate=$aggregate; Details=@($details); CpuTimes=$nextCpuTimes; TimestampUtc=$timestamp }
}

function Assert-PerformanceOutputTargets {
    param(
        [Parameter(Mandatory)][string]$AggregatePath,
        [Parameter(Mandatory)][string]$DetailPath,
        [switch]$Overwrite,
        [scriptblock]$FileExists = { param($Path) [System.IO.File]::Exists($Path) }
    )
    if ($AggregatePath.Equals($DetailPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Aggregate and process-detail CSV paths must be different.'
    }
    $existing = @(@($AggregatePath, $DetailPath) | Where-Object { & $FileExists $_ })
    if ($existing.Count -and -not $Overwrite) {
        throw ('Performance output already exists. Use -Overwrite to replace this run: ' + ($existing -join ', '))
    }
}

function ConvertTo-PerformanceNumber {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$FieldName
    )
    $number = 0.0
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text) -or -not [double]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        throw "Performance field '$FieldName' is not a valid number: $text"
    }
    return $number
}

function Assert-PerformanceAggregateRows {
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [double]$MaximumGapMultiplier = 2.5
    )
    if ($Rows.Count -lt 2) { throw 'Performance CSV must contain at least two aggregate samples.' }
    $requiredFields = @('RecordType','RunId','SampleIndex','TimestampUtc','ElapsedSeconds','IntervalSeconds','RootProcessCount','WebView2ProcessCount','ProcessCount','CPUPercent','WorkingSetBytes','PrivateMemoryBytes','Handles','Threads')
    foreach ($row in $Rows) {
        foreach ($field in $requiredFields) {
            if ($null -eq $row.PSObject.Properties[$field]) { throw "Performance CSV is missing required aggregate field '$field'." }
        }
        if ([string](Get-PerformancePropertyValue -InputObject $row -Name 'RecordType') -ne 'Aggregate') {
            throw 'Performance CSV contains a non-aggregate row.'
        }
    }
    $runIds = @($Rows | ForEach-Object { [string]$_.RunId } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($runIds.Count -ne 1 -or @($Rows | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.RunId) }).Count) {
        throw 'Performance CSV contains missing or mixed RunId values.'
    }
    $intervals = @($Rows | ForEach-Object { ConvertTo-PerformanceNumber -Value $_.IntervalSeconds -FieldName 'IntervalSeconds' } | Select-Object -Unique)
    if ($intervals.Count -ne 1 -or [double]$intervals[0] -le 0) { throw 'Performance CSV contains inconsistent or invalid IntervalSeconds values.' }
    $interval = [double]$intervals[0]
    $minimumGapSeconds = [Math]::Min($interval, [Math]::Max(0.1, $interval * 0.5))
    $maximumGapSeconds = [Math]::Max($interval + 1, $interval * $MaximumGapMultiplier)
    $previousTimestamp = $null
    $previousSampleIndex = -1
    $previousElapsed = -1.0
    $maximumObservedGap = 0.0
    foreach ($row in $Rows) {
        $timestamp = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$row.TimestampUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$timestamp)) {
            throw "Performance CSV contains an invalid TimestampUtc: $($row.TimestampUtc)"
        }
        $timestamp = $timestamp.ToUniversalTime()
        $sampleIndex = [int](ConvertTo-PerformanceNumber -Value $row.SampleIndex -FieldName 'SampleIndex')
        $elapsed = ConvertTo-PerformanceNumber -Value $row.ElapsedSeconds -FieldName 'ElapsedSeconds'
        if ($previousSampleIndex -ge 0 -and $sampleIndex -le $previousSampleIndex) { throw 'Performance CSV sample indices are not strictly increasing.' }
        if ($previousElapsed -ge 0 -and $elapsed -le $previousElapsed) { throw 'Performance CSV elapsed times are not strictly increasing.' }
        if ($null -ne $previousTimestamp) {
            $gap = ($timestamp - $previousTimestamp).TotalSeconds
            if ($gap -le 0) { throw 'Performance CSV timestamps are not strictly increasing.' }
            $maximumObservedGap = [Math]::Max($maximumObservedGap, $gap)
            if ($gap -lt $minimumGapSeconds) {
                throw ("Performance CSV contains an abnormal sample gap: {0:N3}s is below {1:N3}s." -f $gap, $minimumGapSeconds)
            }
            if ($gap -gt $maximumGapSeconds) {
                throw ("Performance CSV contains an abnormal sample gap: {0:N3}s exceeds {1:N3}s." -f $gap, $maximumGapSeconds)
            }
        }
        $rootCount = ConvertTo-PerformanceNumber -Value $row.RootProcessCount -FieldName 'RootProcessCount'
        $webViewCount = ConvertTo-PerformanceNumber -Value $row.WebView2ProcessCount -FieldName 'WebView2ProcessCount'
        $processCount = ConvertTo-PerformanceNumber -Value $row.ProcessCount -FieldName 'ProcessCount'
        if ($rootCount -lt 1 -or $processCount -lt $rootCount -or $webViewCount -gt $processCount) {
            throw 'Performance CSV contains inconsistent process tree counts.'
        }
        foreach ($field in @('WorkingSetBytes','PrivateMemoryBytes','Handles','Threads')) {
            if ((ConvertTo-PerformanceNumber -Value $row.$field -FieldName $field) -lt 0) { throw "Performance field '$field' cannot be negative." }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$row.CPUPercent)) {
            if ((ConvertTo-PerformanceNumber -Value $row.CPUPercent -FieldName 'CPUPercent') -lt 0) {
                throw "Performance field 'CPUPercent' cannot be negative."
            }
        }
        $previousTimestamp = $timestamp
        $previousSampleIndex = $sampleIndex
        $previousElapsed = $elapsed
    }
    [pscustomobject]@{
        RunId = $runIds[0]
        IntervalSeconds = $interval
        MinimumAllowedGapSeconds = $minimumGapSeconds
        MaximumAllowedGapSeconds = $maximumGapSeconds
        MaximumObservedGapSeconds = [Math]::Round($maximumObservedGap, 3)
    }
}
