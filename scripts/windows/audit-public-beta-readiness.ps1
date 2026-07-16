[CmdletBinding()]
param(
    [string]$ResultsRoot,
    [string]$OutputDirectory,
    [string]$UpdaterPublicKeyPath,
    [switch]$AcceptUnsignedRisk,
    [switch]$SkipLegacyDiscovery
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
if ([string]::IsNullOrWhiteSpace($ResultsRoot)) { $ResultsRoot = [System.IO.Path]::Combine($repo, 'qa-results', 'public-beta') }
$root = Resolve-CallerPath -Path $ResultsRoot -BaseDirectory $InvocationDirectory
$output = if ($OutputDirectory) { Resolve-CallerPath -Path $OutputDirectory -BaseDirectory $InvocationDirectory } else { $root }
if (-not [string]::IsNullOrWhiteSpace($UpdaterPublicKeyPath)) { $UpdaterPublicKeyPath = Resolve-CallerPath -Path $UpdaterPublicKeyPath -BaseDirectory $InvocationDirectory }
[System.IO.Directory]::CreateDirectory($output) | Out-Null

$headCommit = (& git -C $repo rev-parse HEAD).Trim()
$releaseDirectory = [System.IO.Path]::Combine($repo, 'release')
$releaseInstaller = Get-DeskPetReleaseInstaller -ReleaseDirectory $releaseDirectory
$releaseVersionContext = Resolve-DeskPetVersionContext -RepositoryRoot $repo -ReleaseDirectory $releaseDirectory -InstallerPath $(if ($releaseInstaller) { $releaseInstaller.FullName } else { $null }) -ExplicitExpectedVersion $null
Assert-DeskPetVersionContext -VersionContext $releaseVersionContext
$releaseManifestPath = [System.IO.Path]::Combine($releaseDirectory, 'release-manifest.json')
$releaseManifest = if ([System.IO.File]::Exists($releaseManifestPath)) { Get-Content -LiteralPath $releaseManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
$releaseManifestCommit = [string](Get-ObjectPropertyValue $releaseManifest 'gitCommit')
$releaseManifestHash = [string](Get-ObjectPropertyValue $releaseManifest 'sha256')
$releaseManifestDirtyValue = Get-ObjectPropertyValue $releaseManifest 'dirtyWorktree'
$releaseManifestClean = $null -ne $releaseManifestDirtyValue -and -not [bool]$releaseManifestDirtyValue
$releaseInstallerHash = if ($releaseInstaller) { (Get-FileHash -LiteralPath $releaseInstaller.FullName -Algorithm SHA256).Hash } else { $null }
$releaseBindingValid = -not [string]::IsNullOrWhiteSpace($releaseManifestCommit) -and $releaseManifestCommit -eq $headCommit -and
    -not [string]::IsNullOrWhiteSpace($releaseManifestHash) -and $releaseManifestHash -eq $releaseInstallerHash -and $releaseManifestClean
$updaterReadiness = Get-DeskPetUpdaterReadiness -RepositoryRoot $repo -ReleaseDirectory $releaseDirectory -ExpectedVersion $releaseVersionContext.ExpectedVersion
$updaterPublicKeyHash = if (-not [string]::IsNullOrWhiteSpace($UpdaterPublicKeyPath) -and [System.IO.File]::Exists($UpdaterPublicKeyPath)) { Get-UpdaterPublicKeyFingerprint -PublicKeyPath $UpdaterPublicKeyPath } else { $null }
$updaterPublicKeyVerified = -not [string]::IsNullOrWhiteSpace($updaterPublicKeyHash) -and $updaterPublicKeyHash -eq $updaterReadiness.PublicKeyFingerprint
$updaterCryptographicSignatureAttempted = $false
$updaterCryptographicSignatureVerified = $false
$updaterCryptographicSignatureError = $null
if (-not [string]::IsNullOrWhiteSpace($UpdaterPublicKeyPath) -and [System.IO.File]::Exists($UpdaterPublicKeyPath) -and
    -not [string]::IsNullOrWhiteSpace([string]$updaterReadiness.ArtifactPath) -and [System.IO.File]::Exists([string]$updaterReadiness.ArtifactPath) -and
    -not [string]::IsNullOrWhiteSpace([string]$updaterReadiness.SignaturePath) -and [System.IO.File]::Exists([string]$updaterReadiness.SignaturePath)) {
    $updaterCryptographicSignatureAttempted = $true
    try {
        $updaterCryptographicSignatureVerified = Test-DeskPetUpdaterArtifactSignature -ArtifactPath $updaterReadiness.ArtifactPath -SignaturePath $updaterReadiness.SignaturePath -PublicKeyPath $UpdaterPublicKeyPath
    } catch {
        $updaterCryptographicSignatureError = $_.Exception.GetType().Name
    }
}

$requirements = @(
    @{id='automatic-release';title='Automated tests and Release build'},
    @{id='current-machine-lifecycle';title='Current machine install, launch, normal exit, and uninstall'},
    @{id='clean-windows-11';title='Clean Windows 11 lifecycle'},
    @{id='clean-windows-10';title='Clean Windows 10 lifecycle'},
    @{id='webview2-online';title='WebView2 missing with network'},
    @{id='webview2-offline';title='WebView2 missing without network'},
    @{id='upgrade-0.1x';title='Upgrade from an older 0.1.x installer'},
    @{id='settings-migration';title='Settings preservation and migration'},
    @{id='no-duplicates';title='No duplicate startup or uninstall records'},
    @{id='single-instance';title='Single instance'},
    @{id='autostart';title='Autostart'},
    @{id='restart';title='Windows restart continuation'},
    @{id='sleep-wake';title='Sleep and wake'},
    @{id='dpi-basic';title='Basic real DPI coverage'},
    @{id='dual-monitor';title='Real dual-monitor coverage'},
    @{id='stability-8h';title='Eight-hour stability run'},
    @{id='defender';title='Windows Defender check'},
    @{id='manifest-hash';title='Manifest and installer hash consistency'},
    @{id='release-evidence-binding';title='QA evidence matches Release commit, version, and installer hash'},
    @{id='public-docs';title='Release, privacy, known issue, and install documentation'},
    @{id='secure-updater';title='Signed HTTPS application updater release'},
    @{id='high-severity-clear';title='No unresolved severe or high-priority issue'}
)

$environmentFiles = @()
if ([System.IO.Directory]::Exists($root)) {
    $environmentFiles = @(Get-ChildItem -LiteralPath $root -Filter 'environment-result.json' -File -Recurse -ErrorAction SilentlyContinue)
}
$parsedEnvironments = @($environmentFiles | ForEach-Object {
    $environmentFile = $_
    try { Get-Content -LiteralPath $environmentFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { [pscustomobject]@{ environmentId=$environmentFile.FullName.Substring($root.Length).TrimStart('\'); status='failed'; checks=@(); notes=@('Invalid environment result JSON.') } }
})
$environments = @($parsedEnvironments | Group-Object -Property environmentId | ForEach-Object {
    @($_.Group | Sort-Object -Property @{ Expression={
        $testedAt = [string](Get-ObjectPropertyValue $_ 'testedAtUtc')
        if ([string]::IsNullOrWhiteSpace($testedAt)) { [DateTime]::MinValue } else { [DateTime]::Parse($testedAt).ToUniversalTime() }
    }; Descending=$true })[0]
})
$evidenceValidation = @()
foreach ($environment in $environments) {
    $validation = Test-DeskPetPublicBetaEvidence -Environment $environment -ExpectedCommit $headCommit -ExpectedVersion $releaseVersionContext.ExpectedVersion -ExpectedInstallerSha256 $releaseInstallerHash
    $environment | Add-Member -NotePropertyName evidenceValid -NotePropertyValue ([bool]$validation.Valid) -Force
    $environment | Add-Member -NotePropertyName evidenceRejectionReasons -NotePropertyValue @($validation.Reasons) -Force
    $evidenceValidation += [pscustomobject]@{ environmentId=[string]$environment.environmentId; valid=[bool]$validation.Valid; reasons=@($validation.Reasons) }
}
$validEnvironments = @($environments | Where-Object { $_.evidenceValid })

$legacy = $null
if (-not $SkipLegacyDiscovery) {
    $legacyCandidates = @(Get-ChildItem -LiteralPath $repo -Directory -Filter 'qa-results-current-machine-*' -ErrorAction SilentlyContinue | ForEach-Object {
        $resultPath = [System.IO.Path]::Combine($_.FullName, 'qa-results.json')
        if ([System.IO.File]::Exists($resultPath) -and $_.Name -notmatch 'preview') { Get-Item -LiteralPath $resultPath }
    } | Sort-Object LastWriteTimeUtc -Descending)
    if ($legacyCandidates.Count) {
        $legacyFile = $legacyCandidates[0]
        $legacyParsed = Get-Content -LiteralPath $legacyFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $legacyRows = @()
        foreach ($legacyRow in $legacyParsed) { $legacyRows += $legacyRow }
        $legacyFailures = @($legacyRows | Where-Object { $_.status -eq 'failed' })
        $singleInstanceEvidence = $null
        foreach ($candidateFile in $legacyCandidates) {
            $candidateParsed = Get-Content -LiteralPath $candidateFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($candidateRow in $candidateParsed) {
                if ($candidateRow.name -eq 'Single instance and normal exit') {
                    $singleInstanceEvidence = [ordered]@{ status=[string]$candidateRow.status; source=$candidateFile.FullName.Substring($repo.Length).TrimStart('\') }
                    break
                }
            }
            if ($null -ne $singleInstanceEvidence) { break }
        }
        $legacy = [ordered]@{
            source=$legacyFile.FullName.Substring($repo.Length).TrimStart('\')
            testedAtUtc=$legacyFile.LastWriteTimeUtc.ToString('o')
            status=$(if ($legacyFailures.Count) { 'failed' } else { 'passed' })
            failedChecks=@($legacyFailures | ForEach-Object { $_.name })
            singleInstance=$singleInstanceEvidence
        }
    }
}

# Pre-schema legacy reports remain visible below for operator context only. They
# cannot open a gate because they lack commit, version, and installer-hash binding.
$evaluated = @()
foreach ($requirement in $requirements) {
    $evidence = @()
    foreach ($environment in $validEnvironments) {
        foreach ($check in @($environment.checks)) {
            if ([string]$check.requirementId -eq $requirement.id) {
                $evidence += [pscustomobject]@{ environmentId=$environment.environmentId; status=[string]$check.status; details=[string]$check.details }
            }
        }
    }
    if ($requirement.id -eq 'release-evidence-binding') {
        $rejectedCount = @($evidenceValidation | Where-Object { -not $_.valid }).Count
        $bindingStatus = if ($releaseBindingValid -and -not $rejectedCount) { 'passed' } else { 'failed' }
        $evidence += [pscustomobject]@{ environmentId='release'; status=$bindingStatus; details="releaseBindingValid=$releaseBindingValid; rejectedEvidence=$rejectedCount" }
    }
    if ($requirement.id -eq 'secure-updater') {
        $updaterStatus = if ($updaterReadiness.State -eq 'READY' -and $updaterPublicKeyVerified -and $updaterCryptographicSignatureVerified) { 'passed' } elseif ($updaterReadiness.State -eq 'NOT_CONFIGURED' -or -not $updaterPublicKeyVerified) { 'blocked' } else { 'failed' }
        $evidence += [pscustomobject]@{ environmentId='release-updater'; status=$updaterStatus; details="state=$($updaterReadiness.State); publicKeyVerified=$updaterPublicKeyVerified; cryptographicSignatureVerified=$updaterCryptographicSignatureVerified" }
    }
    $status = 'not_executed'
    if (@($evidence | Where-Object status -eq 'failed').Count) { $status = 'failed' }
    elseif (@($evidence | Where-Object status -eq 'passed').Count) { $status = 'passed' }
    elseif (@($evidence | Where-Object status -eq 'blocked').Count) { $status = 'blocked' }
    $evaluated += [pscustomobject]@{ id=$requirement.id; title=$requirement.title; status=$status; evidence=@($evidence) }
}

$signatureStatus = if ($releaseInstaller) { [string](Get-AuthenticodeSignature -FilePath $releaseInstaller.FullName).Status } else { 'InstallerMissing' }
$failedRequired = @($evaluated | Where-Object status -eq 'failed')
$pendingRequired = @($evaluated | Where-Object status -ne 'passed')
if ($updaterReadiness.State -eq 'NOT_CONFIGURED' -or -not $updaterPublicKeyVerified) { $gate = 'BLOCKED' }
elseif ($updaterReadiness.State -ne 'READY' -or -not $updaterCryptographicSignatureVerified -or -not $releaseBindingValid) { $gate = 'NOT_READY' }
elseif ($failedRequired.Count) { $gate = 'NOT_READY' }
elseif ($pendingRequired.Count) { $gate = 'INTERNAL_TEST_ONLY' }
elseif ($signatureStatus -eq 'Valid' -or $AcceptUnsignedRisk) { $gate = 'PUBLIC_BETA_READY' }
else { $gate = 'PUBLIC_BETA_CANDIDATE' }

$audit = [ordered]@{
    schemaVersion=1; generatedAtUtc=[DateTime]::UtcNow.ToString('o'); gate=$gate
    gitCommit=$headCommit; signatureStatus=$signatureStatus
    expectedVersion=$releaseVersionContext.ExpectedVersion; installerVersion=$releaseVersionContext.InstallerVersion; releaseManifestVersion=$releaseVersionContext.ManifestVersion
    releaseBindingValid=$releaseBindingValid; updaterStatus=$updaterReadiness.State; updaterPublicKeyVerified=$updaterPublicKeyVerified
    updaterCryptographicSignatureAttempted=$updaterCryptographicSignatureAttempted; updaterCryptographicSignatureVerified=$updaterCryptographicSignatureVerified
    unsignedRiskAccepted=[bool]$AcceptUnsignedRisk; requirements=@($evaluated)
    environmentResults=@($environments | ForEach-Object { [ordered]@{ environmentId=$_.environmentId; status=$_.status; testedAtUtc=$_.testedAtUtc; gitCommit=$_.gitCommit; evidenceValid=$_.evidenceValid; evidenceRejectionReasons=@($_.evidenceRejectionReasons) } })
    legacyCurrentMachine=$legacy
    counts=[ordered]@{ passed=@($evaluated|Where-Object status -eq 'passed').Count; failed=$failedRequired.Count; blocked=@($evaluated|Where-Object status -eq 'blocked').Count; notExecuted=@($evaluated|Where-Object status -eq 'not_executed').Count }
    risks=@(
        $(if ($signatureStatus -ne 'Valid') { 'Unsigned public beta risk' }),
        $(if ($pendingRequired.Count) { 'Required QA remains incomplete.' }),
        $(if ($updaterReadiness.State -eq 'NOT_CONFIGURED') { 'Updater is NOT_CONFIGURED; public beta publication is blocked.' }),
        $(if ($updaterReadiness.State -ne 'NOT_CONFIGURED' -and -not $updaterPublicKeyVerified) { 'Updater production public key is missing or does not match the release fingerprint.' }),
        $(if ($updaterReadiness.State -ne 'NOT_CONFIGURED' -and $updaterPublicKeyVerified -and -not $updaterCryptographicSignatureVerified) { "Updater artifact signature was not cryptographically verified ($updaterCryptographicSignatureError)." }),
        $(if (-not $releaseBindingValid) { 'Release manifest commit or installer hash does not match the current Release.' }),
        $(if (@($evidenceValidation | Where-Object { -not $_.valid }).Count) { 'Stale or mismatched QA evidence was rejected.' })
    ) | Where-Object { $_ }
}
$jsonPath = [System.IO.Path]::Combine($output, 'public-beta-readiness.json')
$mdPath = [System.IO.Path]::Combine($output, 'public-beta-readiness.md')
$audit | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
$lines = @('# Public beta readiness', '', "- Gate: **$gate**", "- Git commit: $($audit.gitCommit)", "- Signature: $signatureStatus", "- Updater: $($updaterReadiness.State)", "- Release binding valid: $releaseBindingValid", "- Generated UTC: $($audit.generatedAtUtc)", '', '| Requirement | Status | Evidence |', '|---|---|---|')
$lines += @($evaluated | ForEach-Object { $evidenceText = @($_.evidence | ForEach-Object { "$($_.environmentId): $($_.details)" }) -join '; '; "| $($_.title) | $($_.status) | $($evidenceText -replace '\|','/') |" })
$lines += @('', '## Risks', '') + @($audit.risks | ForEach-Object { "- $_" })
($lines -join [Environment]::NewLine) | Set-Content -LiteralPath $mdPath -Encoding UTF8
Write-Host "Public beta gate: $gate"
Write-Host "Readiness report: $mdPath"
