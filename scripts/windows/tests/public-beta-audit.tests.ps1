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
function New-PassingApplicationUpdaterChecks {
    @(
        'Version A updater artifact cryptographically verified','Version B updater artifact cryptographically verified',
        'Remote endpoint candidate binding','Version B installer was not invoked by QA',
        'Updater UI pending target observed','Updater UI target confirmed after restart',
        'Updater UI ordered pending-to-confirmed transition','Old version process exited','New version process started',
        'New process uses version B executable','Version B installation record','Single uninstall record',
        'Settings preserved','Character selection preserved','Imported character package preserved and loadable',
        'Autostart state preserved','No duplicate autostart','Start menu shortcut preserved'
    ) | ForEach-Object { [ordered]@{name=$_;passed=$true} }
}

try {
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    & ([System.IO.Path]::Combine($windowsRoot, 'audit-public-beta-readiness.ps1')) -ResultsRoot $root -OutputDirectory $root -SkipLegacyDiscovery
    $emptyAudit = Get-Content -LiteralPath ([System.IO.Path]::Combine($root, 'public-beta-readiness.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Test 'Configured updater remains blocked without production public-key verification' 'BLOCKED' $emptyAudit.gate
    Add-Test 'Updater status is explicitly READY' 'READY' $emptyAudit.updaterStatus
    $automaticRequirement = @($emptyAudit.requirements | Where-Object id -eq 'automatic-release')[0]
    Add-Test 'Missing environment evidence is not passed' 'not_executed' ([string]$automaticRequirement.status)

    & ([System.IO.Path]::Combine($windowsRoot, 'audit-public-beta-readiness.ps1')) -ResultsRoot $root -OutputDirectory $root -SkipLegacyDiscovery -AcceptUnsignedRisk
    $acceptedRiskAudit = Get-Content -LiteralPath ([System.IO.Path]::Combine($root, 'public-beta-readiness.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Test 'AcceptUnsignedRisk cannot bypass missing updater key verification' 'BLOCKED' $acceptedRiskAudit.gate

    $directOverlayEnvironment = [ordered]@{
        schemaVersion=1; environmentId='direct-overlay'; status='passed'; testedAtUtc=[DateTime]::UtcNow.ToString('o'); gitCommit=(& git -C $repo rev-parse HEAD).Trim()
        expectedVersion=[string]$releaseManifest.version; artifact=[ordered]@{ installerSha256=[string]$releaseManifest.sha256; installerFile=[string]$releaseManifest.installerFile; sizeBytes=[long]$releaseManifest.installerSizeBytes }
        evidenceType='direct_installer_overlay'; sourceReportStatus='passed'
        checks=@([ordered]@{ requirementId='application-updater-e2e'; status='passed'; details='must be rejected' })
    }
    $directOverlayDirectory = [System.IO.Path]::Combine($root, 'direct-overlay')
    [System.IO.Directory]::CreateDirectory($directOverlayDirectory) | Out-Null
    $directOverlayEnvironment | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ([System.IO.Path]::Combine($directOverlayDirectory, 'environment-result.json')) -Encoding UTF8
    & ([System.IO.Path]::Combine($windowsRoot, 'audit-public-beta-readiness.ps1')) -ResultsRoot $root -OutputDirectory $root -SkipLegacyDiscovery
    $directOverlayAudit = Get-Content -LiteralPath ([System.IO.Path]::Combine($root, 'public-beta-readiness.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    $directOverlayRequirement = @($directOverlayAudit.requirements | Where-Object id -eq 'application-updater-e2e')[0]
    Add-Test 'Direct installer overlay cannot satisfy application updater E2E' 'not_executed' ([string]$directOverlayRequirement.status)
    [System.IO.Directory]::Delete($directOverlayDirectory, $true)

    $ids = @('automatic-release','current-machine-lifecycle','clean-windows-11','clean-windows-10','webview2-online','webview2-offline','upgrade-0.1x','application-updater-e2e','settings-migration','no-duplicates','single-instance','autostart','restart','sleep-wake','dpi-basic','dual-monitor','stability-8h','defender','manifest-hash','public-docs','high-severity-clear')
    $environment = [ordered]@{
        schemaVersion=1; environmentId='synthetic'; status='passed'; testedAtUtc=[DateTime]::UtcNow.ToString('o'); gitCommit=(& git -C $repo rev-parse HEAD).Trim()
        expectedVersion=[string]$releaseManifest.version; artifact=[ordered]@{ installerSha256=[string]$releaseManifest.sha256; installerFile=[string]$releaseManifest.installerFile; sizeBytes=[long]$releaseManifest.installerSizeBytes }
        evidenceType='application_updater_e2e'; sourceReportStatus='passed'
        checks=@($ids | ForEach-Object { [ordered]@{ requirementId=$_; status='passed'; details='synthetic unit-test evidence' } })
    }
    $environmentDirectory = [System.IO.Path]::Combine($root, 'synthetic')
    [System.IO.Directory]::CreateDirectory($environmentDirectory) | Out-Null
    $environment | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ([System.IO.Path]::Combine($environmentDirectory, 'environment-result.json')) -Encoding UTF8
    & ([System.IO.Path]::Combine($windowsRoot, 'audit-public-beta-readiness.ps1')) -ResultsRoot $root -OutputDirectory $root -SkipLegacyDiscovery
    $summaryOnlyAudit = Get-Content -LiteralPath ([System.IO.Path]::Combine($root, 'public-beta-readiness.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    $summaryOnlyRequirement = @($summaryOnlyAudit.requirements | Where-Object id -eq 'application-updater-e2e')[0]
    Add-Test 'Synthetic application updater summary without raw evidence is rejected' 'blocked' ([string]$summaryOnlyRequirement.status)

    $rawDirectory = [System.IO.Path]::Combine($environmentDirectory, 'raw')
    [System.IO.Directory]::CreateDirectory($rawDirectory) | Out-Null
    $rawPath = [System.IO.Path]::Combine($rawDirectory, 'application-updater-result.json')
    $previousHash = 'A' * 64
    $rawEvidence = [ordered]@{
        schemaVersion=1; evidenceType='application_updater_e2e'; phase='completed'; status='passed'; whatIf=$false; failure=$null; finalProbeStatus='passed'
        currentVersion=[string]$releaseManifest.version; previousInstallerSha256=$previousHash
        currentInstallerReferenceFile=[string]$releaseManifest.installerFile; currentInstallerExecutionAllowed=$false; currentInstallerSha256=[string]$releaseManifest.sha256
        publicKeyFingerprint=('C' * 64); installerExecutions=@([ordered]@{role='version_a';sha256=$previousHash})
        cryptographicallyVerifiedArtifactRoles=@('version_a','version_b')
        endpointCandidateBinding=$true; remoteLatestSha256=('B' * 64); remoteArtifactSignatureSha256=('D' * 64)
        remoteArtifactFile=[string]$releaseManifest.installerFile; remoteArtifactSizeBytes=[long]$releaseManifest.installerSizeBytes
        uiPendingTargetObserved=$true; uiConfirmedTargetObserved=$true; uiPendingClearedAfterConfirmation=$true; uiOrderedTransitionObserved=$true
        checks=@(New-PassingApplicationUpdaterChecks)
    }
    $minimalRawEvidence = [ordered]@{}
    foreach ($key in $rawEvidence.Keys) { $minimalRawEvidence[$key] = $rawEvidence[$key] }
    $minimalRawEvidence['checks'] = @(
        [ordered]@{name='Updater UI pending target observed';passed=$true},
        [ordered]@{name='Updater UI target confirmed after restart';passed=$true},
        [ordered]@{name='Remote endpoint candidate binding';passed=$true}
    )
    [System.IO.File]::WriteAllText($rawPath, ($minimalRawEvidence | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    $environment['sourceReportFile'] = [System.IO.Path]::Combine('raw','application-updater-result.json')
    $environment['sourceReportSha256'] = (Get-FileHash -LiteralPath $rawPath -Algorithm SHA256).Hash
    $environment | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath ([System.IO.Path]::Combine($environmentDirectory, 'environment-result.json')) -Encoding UTF8
    & ([System.IO.Path]::Combine($windowsRoot, 'audit-public-beta-readiness.ps1')) -ResultsRoot $root -OutputDirectory $root -SkipLegacyDiscovery
    $minimalRawAudit = Get-Content -LiteralPath ([System.IO.Path]::Combine($root, 'public-beta-readiness.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    $minimalRawRequirement = @($minimalRawAudit.requirements | Where-Object id -eq 'application-updater-e2e')[0]
    Add-Test 'Minimal synthetic raw report cannot satisfy application updater E2E' 'blocked' ([string]$minimalRawRequirement.status)

    [System.IO.File]::WriteAllText($rawPath, ($rawEvidence | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    $environment['sourceReportSha256'] = (Get-FileHash -LiteralPath $rawPath -Algorithm SHA256).Hash
    $environment | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath ([System.IO.Path]::Combine($environmentDirectory, 'environment-result.json')) -Encoding UTF8
    & ([System.IO.Path]::Combine($windowsRoot, 'audit-public-beta-readiness.ps1')) -ResultsRoot $root -OutputDirectory $root -SkipLegacyDiscovery
    $completeAudit = Get-Content -LiteralPath ([System.IO.Path]::Combine($root, 'public-beta-readiness.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Test 'Complete evidence remains blocked without updater key verification' 'BLOCKED' $completeAudit.gate
    Add-Test 'Matching commit, version and hash evidence is accepted' $true ([bool]$completeAudit.environmentResults[0].evidenceValid)
    $applicationUpdaterRequirement = @($completeAudit.requirements | Where-Object id -eq 'application-updater-e2e')[0]
    Add-Test 'Explicit passed application updater report satisfies its independent requirement' 'passed' ([string]$applicationUpdaterRequirement.status)
    $stringSchemaEnvironment = [pscustomobject]@{
        schemaVersion='1'; gitCommit=$environment.gitCommit; expectedVersion=$environment.expectedVersion; artifact=$environment.artifact
    }
    $stringSchemaEnvironmentValidation = Test-DeskPetPublicBetaEvidence -Environment $stringSchemaEnvironment `
        -ExpectedCommit $environment.gitCommit -ExpectedVersion ([string]$releaseManifest.version) -ExpectedInstallerSha256 ([string]$releaseManifest.sha256)
    Add-Test 'String environment schemaVersion fails closed' $false ([bool]$stringSchemaEnvironmentValidation.Valid)

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
    Add-Test 'Updater key-verification block is not bypassed by other failed evidence' 'BLOCKED' $failedAudit.gate

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
