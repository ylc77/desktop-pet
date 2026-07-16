[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$windowsRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..'))
$repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($windowsRoot, '..', '..'))
$root = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'desk-pet-public-beta-test-' + [guid]::NewGuid().ToString('N'))
$results = @()
function Add-Test([string]$Name, [object]$Expected, [object]$Actual) {
    $script:results += [pscustomobject]@{ Name=$Name; Passed=$Expected -eq $Actual; Details="expected=$Expected; actual=$Actual" }
}

try {
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    & ([System.IO.Path]::Combine($windowsRoot, 'audit-public-beta-readiness.ps1')) -ResultsRoot $root -OutputDirectory $root -SkipLegacyDiscovery
    $emptyAudit = Get-Content -LiteralPath ([System.IO.Path]::Combine($root, 'public-beta-readiness.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Test 'Missing evidence remains internal-only' 'INTERNAL_TEST_ONLY' $emptyAudit.gate
    Add-Test 'Missing evidence is not passed' 0 $emptyAudit.counts.passed

    $ids = @('automatic-release','current-machine-lifecycle','clean-windows-11','clean-windows-10','webview2-online','webview2-offline','upgrade-0.1x','settings-migration','no-duplicates','single-instance','autostart','restart','sleep-wake','dpi-basic','dual-monitor','stability-8h','defender','manifest-hash','public-docs','high-severity-clear')
    $environment = [ordered]@{
        schemaVersion=1; environmentId='synthetic'; status='passed'; testedAtUtc=[DateTime]::UtcNow.ToString('o'); gitCommit=(& git -C $repo rev-parse HEAD).Trim()
        checks=@($ids | ForEach-Object { [ordered]@{ requirementId=$_; status='passed'; details='synthetic unit-test evidence' } })
    }
    $environmentDirectory = [System.IO.Path]::Combine($root, 'synthetic')
    [System.IO.Directory]::CreateDirectory($environmentDirectory) | Out-Null
    $environment | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ([System.IO.Path]::Combine($environmentDirectory, 'environment-result.json')) -Encoding UTF8
    & ([System.IO.Path]::Combine($windowsRoot, 'audit-public-beta-readiness.ps1')) -ResultsRoot $root -OutputDirectory $root -SkipLegacyDiscovery
    $completeAudit = Get-Content -LiteralPath ([System.IO.Path]::Combine($root, 'public-beta-readiness.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Test 'Complete unsigned evidence is candidate, not ready' 'PUBLIC_BETA_CANDIDATE' $completeAudit.gate

    $olderEnvironment = [ordered]@{
        schemaVersion=1; environmentId='synthetic'; status='failed'; testedAtUtc='2000-01-01T00:00:00Z'; gitCommit=$environment.gitCommit
        checks=@($ids | ForEach-Object { [ordered]@{ requirementId=$_; status=$(if($_ -eq 'automatic-release'){'failed'}else{'passed'}); details='older synthetic evidence' } })
    }
    $olderDirectory = [System.IO.Path]::Combine($root, 'synthetic-old')
    [System.IO.Directory]::CreateDirectory($olderDirectory) | Out-Null
    $olderEnvironment | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ([System.IO.Path]::Combine($olderDirectory, 'environment-result.json')) -Encoding UTF8
    & ([System.IO.Path]::Combine($windowsRoot, 'audit-public-beta-readiness.ps1')) -ResultsRoot $root -OutputDirectory $root -SkipLegacyDiscovery
    $deduplicatedAudit = Get-Content -LiteralPath ([System.IO.Path]::Combine($root, 'public-beta-readiness.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Test 'Latest result replaces older evidence from the same environment' 'PUBLIC_BETA_CANDIDATE' $deduplicatedAudit.gate

    $environment.checks[0].status = 'failed'
    $environment | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ([System.IO.Path]::Combine($environmentDirectory, 'environment-result.json')) -Encoding UTF8
    & ([System.IO.Path]::Combine($windowsRoot, 'audit-public-beta-readiness.ps1')) -ResultsRoot $root -OutputDirectory $root -SkipLegacyDiscovery
    $failedAudit = Get-Content -LiteralPath ([System.IO.Path]::Combine($root, 'public-beta-readiness.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Test 'Failed required evidence forces NOT_READY' 'NOT_READY' $failedAudit.gate

    $csv = [System.IO.Path]::Combine($root, 'performance.csv')
    @(
        [pscustomobject]@{RecordType='Aggregate';RunId='synthetic-eight-hour';SampleIndex=0;TimestampUtc='2026-01-01T00:00:00Z';ElapsedSeconds=0;IntervalSeconds=14400;RootProcessCount=1;WebView2ProcessCount=4;ProcessCount=5;CPUPercent='';WorkingSetBytes=100;PrivateMemoryBytes=80;Handles=10;Threads=2},
        [pscustomobject]@{RecordType='Aggregate';RunId='synthetic-eight-hour';SampleIndex=1;TimestampUtc='2026-01-01T04:00:00Z';ElapsedSeconds=14400;IntervalSeconds=14400;RootProcessCount=1;WebView2ProcessCount=4;ProcessCount=5;CPUPercent=2;WorkingSetBytes=110;PrivateMemoryBytes=85;Handles=11;Threads=2},
        [pscustomobject]@{RecordType='Aggregate';RunId='synthetic-eight-hour';SampleIndex=2;TimestampUtc='2026-01-01T08:00:00Z';ElapsedSeconds=28800;IntervalSeconds=14400;RootProcessCount=1;WebView2ProcessCount=4;ProcessCount=5;CPUPercent=1;WorkingSetBytes=105;PrivateMemoryBytes=84;Handles=10;Threads=2}
    ) | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    $analysisPath = [System.IO.Path]::Combine($root, 'performance-analysis.json')
    & ([System.IO.Path]::Combine($windowsRoot, 'analyze-performance.ps1')) -InputPath $csv -OutputPath ([System.IO.Path]::Combine($root, 'performance-summary.md')) -JsonOutputPath $analysisPath | Out-Null
    $analysis = Get-Content -LiteralPath $analysisPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Test 'Eight-hour duration is detected' 'eight_hour_duration_captured' $analysis.durationCategory
    Add-Test 'Eight-hour data still requires manual review' 'requires_manual_review' $analysis.assessment
} finally {
    if ([System.IO.Directory]::Exists($root)) { [System.IO.Directory]::Delete($root, $true) }
}

$results | Format-Table -AutoSize
$hostIsPowerShell51 = $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
[pscustomobject]@{ Name='Windows PowerShell 5.1 host'; Passed=$hostIsPowerShell51; Details=$PSVersionTable.PSVersion.ToString() } | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -or -not $hostIsPowerShell51) { exit 1 }
