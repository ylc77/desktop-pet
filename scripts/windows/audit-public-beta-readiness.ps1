[CmdletBinding()]
param(
    [string]$ResultsRoot,
    [string]$OutputDirectory,
    [switch]$AcceptUnsignedRisk,
    [switch]$SkipLegacyDiscovery
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
if ([string]::IsNullOrWhiteSpace($ResultsRoot)) { $ResultsRoot = [System.IO.Path]::Combine($repo, 'qa-results', 'public-beta') }
$root = [System.IO.Path]::GetFullPath($ResultsRoot)
$output = if ($OutputDirectory) { [System.IO.Path]::GetFullPath($OutputDirectory) } else { $root }
[System.IO.Directory]::CreateDirectory($output) | Out-Null

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
    @{id='public-docs';title='Release, privacy, known issue, and install documentation'},
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

$standardCurrent = $environments | Where-Object environmentId -eq 'current-machine' | Select-Object -First 1
$standardCurrentLifecycle = @(if ($standardCurrent) { $standardCurrent.checks | Where-Object requirementId -eq 'current-machine-lifecycle' | Select-Object -First 1 })
$standardSingleInstance = @(if ($standardCurrent) { $standardCurrent.checks | Where-Object requirementId -eq 'single-instance' | Select-Object -First 1 })
$standardHighSeverity = @(if ($standardCurrent) { $standardCurrent.checks | Where-Object requirementId -eq 'high-severity-clear' | Select-Object -First 1 })
$evaluated = @()
foreach ($requirement in $requirements) {
    $evidence = @()
    foreach ($environment in $environments) {
        foreach ($check in @($environment.checks)) {
            if ([string]$check.requirementId -eq $requirement.id) {
                $evidence += [pscustomobject]@{ environmentId=$environment.environmentId; status=[string]$check.status; details=[string]$check.details }
            }
        }
    }
    if ($requirement.id -eq 'current-machine-lifecycle' -and $null -ne $legacy -and -not $standardCurrentLifecycle.Count) {
        $evidence += [pscustomobject]@{ environmentId='current-machine-legacy'; status=$legacy.status; details="source=$($legacy.source); failures=$($legacy.failedChecks -join ', ')" }
    }
    if ($requirement.id -eq 'single-instance' -and $null -ne $legacy -and $null -ne $legacy.singleInstance -and -not $standardSingleInstance.Count) {
        $evidence += [pscustomobject]@{ environmentId='current-machine-legacy'; status=$legacy.singleInstance.status; details="source=$($legacy.singleInstance.source)" }
    }
    if ($requirement.id -eq 'high-severity-clear' -and $null -ne $legacy -and $legacy.status -eq 'failed' -and -not $standardHighSeverity.Count) {
        $evidence += [pscustomobject]@{ environmentId='current-machine-legacy'; status='failed'; details='A real current-machine uninstall failure remains unresolved.' }
    }
    $status = 'not_executed'
    if (@($evidence | Where-Object status -eq 'failed').Count) { $status = 'failed' }
    elseif (@($evidence | Where-Object status -eq 'passed').Count) { $status = 'passed' }
    elseif (@($evidence | Where-Object status -eq 'blocked').Count) { $status = 'blocked' }
    $evaluated += [pscustomobject]@{ id=$requirement.id; title=$requirement.title; status=$status; evidence=@($evidence) }
}

$releaseInstaller = Get-DeskPetReleaseInstaller -ReleaseDirectory ([System.IO.Path]::Combine($repo, 'release'))
$signatureStatus = if ($releaseInstaller) { [string](Get-AuthenticodeSignature -FilePath $releaseInstaller.FullName).Status } else { 'InstallerMissing' }
$failedRequired = @($evaluated | Where-Object status -eq 'failed')
$pendingRequired = @($evaluated | Where-Object status -ne 'passed')
if ($failedRequired.Count) { $gate = 'NOT_READY' }
elseif ($pendingRequired.Count) { $gate = 'INTERNAL_TEST_ONLY' }
elseif ($signatureStatus -eq 'Valid' -or $AcceptUnsignedRisk) { $gate = 'PUBLIC_BETA_READY' }
else { $gate = 'PUBLIC_BETA_CANDIDATE' }

$audit = [ordered]@{
    schemaVersion=1; generatedAtUtc=[DateTime]::UtcNow.ToString('o'); gate=$gate
    gitCommit=(& git -C $repo rev-parse HEAD).Trim(); signatureStatus=$signatureStatus
    unsignedRiskAccepted=[bool]$AcceptUnsignedRisk; requirements=@($evaluated)
    environmentResults=@($environments | ForEach-Object { [ordered]@{ environmentId=$_.environmentId; status=$_.status; testedAtUtc=$_.testedAtUtc; gitCommit=$_.gitCommit } })
    legacyCurrentMachine=$legacy
    counts=[ordered]@{ passed=@($evaluated|Where-Object status -eq 'passed').Count; failed=$failedRequired.Count; blocked=@($evaluated|Where-Object status -eq 'blocked').Count; notExecuted=@($evaluated|Where-Object status -eq 'not_executed').Count }
    risks=@($(if ($signatureStatus -ne 'Valid') { 'Unsigned public beta risk' }), $(if ($pendingRequired.Count) { 'Required QA remains incomplete.' })) | Where-Object { $_ }
}
$jsonPath = [System.IO.Path]::Combine($output, 'public-beta-readiness.json')
$mdPath = [System.IO.Path]::Combine($output, 'public-beta-readiness.md')
$audit | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
$lines = @('# Public beta readiness', '', "- Gate: **$gate**", "- Git commit: $($audit.gitCommit)", "- Signature: $signatureStatus", "- Generated UTC: $($audit.generatedAtUtc)", '', '| Requirement | Status | Evidence |', '|---|---|---|')
$lines += @($evaluated | ForEach-Object { $evidenceText = @($_.evidence | ForEach-Object { "$($_.environmentId): $($_.details)" }) -join '; '; "| $($_.title) | $($_.status) | $($evidenceText -replace '\|','/') |" })
$lines += @('', '## Risks', '') + @($audit.risks | ForEach-Object { "- $_" })
($lines -join [Environment]::NewLine) | Set-Content -LiteralPath $mdPath -Encoding UTF8
Write-Host "Public beta gate: $gate"
Write-Host "Readiness report: $mdPath"
