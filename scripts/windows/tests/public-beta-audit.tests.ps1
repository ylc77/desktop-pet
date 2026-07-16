[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$windowsRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..'))
$repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($windowsRoot, '..', '..'))
. ([System.IO.Path]::Combine($windowsRoot, 'common.ps1'))
$releaseManifest = Get-Content -LiteralPath ([System.IO.Path]::Combine($repo, 'release', 'release-manifest.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
$root = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'desk-pet-public-beta-test-' + [guid]::NewGuid().ToString('N'))
$results = @()
function Add-Test([string]$Name, [object]$Expected, [object]$Actual) {
    $script:results += [pscustomobject]@{ Name=$Name; Passed=$Expected -eq $Actual; Details="expected=$Expected; actual=$Actual" }
}

try {
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    & ([System.IO.Path]::Combine($windowsRoot, 'audit-public-beta-readiness.ps1')) -ResultsRoot $root -OutputDirectory $root -SkipLegacyDiscovery
    $emptyAudit = Get-Content -LiteralPath ([System.IO.Path]::Combine($root, 'public-beta-readiness.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Test 'Missing updater configuration blocks public beta gate' 'BLOCKED' $emptyAudit.gate
    Add-Test 'Updater status is explicitly NOT_CONFIGURED' 'NOT_CONFIGURED' $emptyAudit.updaterStatus
    $automaticRequirement = @($emptyAudit.requirements | Where-Object id -eq 'automatic-release')[0]
    Add-Test 'Missing environment evidence is not passed' 'not_executed' ([string]$automaticRequirement.status)

    & ([System.IO.Path]::Combine($windowsRoot, 'audit-public-beta-readiness.ps1')) -ResultsRoot $root -OutputDirectory $root -SkipLegacyDiscovery -AcceptUnsignedRisk
    $acceptedRiskAudit = Get-Content -LiteralPath ([System.IO.Path]::Combine($root, 'public-beta-readiness.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Test 'AcceptUnsignedRisk cannot bypass a missing updater' 'BLOCKED' $acceptedRiskAudit.gate

    $ids = @('automatic-release','current-machine-lifecycle','clean-windows-11','clean-windows-10','webview2-online','webview2-offline','upgrade-0.1x','settings-migration','no-duplicates','single-instance','autostart','restart','sleep-wake','dpi-basic','dual-monitor','stability-8h','defender','manifest-hash','public-docs','high-severity-clear')
    $environment = [ordered]@{
        schemaVersion=1; environmentId='synthetic'; status='passed'; testedAtUtc=[DateTime]::UtcNow.ToString('o'); gitCommit=(& git -C $repo rev-parse HEAD).Trim()
        expectedVersion=[string]$releaseManifest.version; artifact=[ordered]@{ installerSha256=[string]$releaseManifest.sha256 }
        checks=@($ids | ForEach-Object { [ordered]@{ requirementId=$_; status='passed'; details='synthetic unit-test evidence' } })
    }
    $environmentDirectory = [System.IO.Path]::Combine($root, 'synthetic')
    [System.IO.Directory]::CreateDirectory($environmentDirectory) | Out-Null
    $environment | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ([System.IO.Path]::Combine($environmentDirectory, 'environment-result.json')) -Encoding UTF8
    & ([System.IO.Path]::Combine($windowsRoot, 'audit-public-beta-readiness.ps1')) -ResultsRoot $root -OutputDirectory $root -SkipLegacyDiscovery
    $completeAudit = Get-Content -LiteralPath ([System.IO.Path]::Combine($root, 'public-beta-readiness.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Test 'Complete evidence remains blocked without updater configuration' 'BLOCKED' $completeAudit.gate
    Add-Test 'Matching commit, version and hash evidence is accepted' $true ([bool]$completeAudit.environmentResults[0].evidenceValid)

    $olderEnvironment = [ordered]@{
        schemaVersion=1; environmentId='synthetic'; status='failed'; testedAtUtc='2000-01-01T00:00:00Z'; gitCommit=$environment.gitCommit
        expectedVersion=$environment.expectedVersion; artifact=$environment.artifact
        checks=@($ids | ForEach-Object { [ordered]@{ requirementId=$_; status=$(if($_ -eq 'automatic-release'){'failed'}else{'passed'}); details='older synthetic evidence' } })
    }
    $olderDirectory = [System.IO.Path]::Combine($root, 'synthetic-old')
    [System.IO.Directory]::CreateDirectory($olderDirectory) | Out-Null
    $olderEnvironment | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ([System.IO.Path]::Combine($olderDirectory, 'environment-result.json')) -Encoding UTF8
    & ([System.IO.Path]::Combine($windowsRoot, 'audit-public-beta-readiness.ps1')) -ResultsRoot $root -OutputDirectory $root -SkipLegacyDiscovery
    $deduplicatedAudit = Get-Content -LiteralPath ([System.IO.Path]::Combine($root, 'public-beta-readiness.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Test 'Latest result replaces older evidence from the same environment' 'BLOCKED' $deduplicatedAudit.gate

    $environment.checks[0].status = 'failed'
    $environment | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ([System.IO.Path]::Combine($environmentDirectory, 'environment-result.json')) -Encoding UTF8
    & ([System.IO.Path]::Combine($windowsRoot, 'audit-public-beta-readiness.ps1')) -ResultsRoot $root -OutputDirectory $root -SkipLegacyDiscovery
    $failedAudit = Get-Content -LiteralPath ([System.IO.Path]::Combine($root, 'public-beta-readiness.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Test 'Updater block is not bypassed by other failed evidence' 'BLOCKED' $failedAudit.gate

    $staleEnvironment = [pscustomobject]@{
        gitCommit='0000000000000000000000000000000000000000'; expectedVersion=[string]$releaseManifest.version
        artifact=[pscustomobject]@{ installerSha256=[string]$releaseManifest.sha256 }
    }
    $staleValidation = Test-DeskPetPublicBetaEvidence -Environment $staleEnvironment -ExpectedCommit $environment.gitCommit -ExpectedVersion ([string]$releaseManifest.version) -ExpectedInstallerSha256 ([string]$releaseManifest.sha256)
    Add-Test 'Evidence from an older commit is rejected' $false ([bool]$staleValidation.Valid)
    $wrongVersionEnvironment = [pscustomobject]@{
        gitCommit=$environment.gitCommit; expectedVersion='9.9.9'; artifact=[pscustomobject]@{ installerSha256=[string]$releaseManifest.sha256 }
    }
    $wrongVersionValidation = Test-DeskPetPublicBetaEvidence -Environment $wrongVersionEnvironment -ExpectedCommit $environment.gitCommit -ExpectedVersion ([string]$releaseManifest.version) -ExpectedInstallerSha256 ([string]$releaseManifest.sha256)
    Add-Test 'Evidence for a different version is rejected' $false ([bool]$wrongVersionValidation.Valid)
    $wrongHashEnvironment = [pscustomobject]@{
        gitCommit=$environment.gitCommit; expectedVersion=[string]$releaseManifest.version; artifact=[pscustomobject]@{ installerSha256=('0' * 64) }
    }
    $wrongHashValidation = Test-DeskPetPublicBetaEvidence -Environment $wrongHashEnvironment -ExpectedCommit $environment.gitCommit -ExpectedVersion ([string]$releaseManifest.version) -ExpectedInstallerSha256 ([string]$releaseManifest.sha256)
    Add-Test 'Evidence for a different installer hash is rejected' $false ([bool]$wrongHashValidation.Valid)

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
