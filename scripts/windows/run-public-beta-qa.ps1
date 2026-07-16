[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Safe','CurrentMachine','Sandbox','CleanWindows11','CleanWindows10','Upgrade','ApplicationUpdater','Performance','PublicBetaAudit')][string]$Mode = 'PublicBetaAudit',
    [string]$OutputDirectory,
    [string]$InstallerPath,
    [string]$PreviousInstallerPath,
    [string]$PreviousUpdaterManifestPath,
    [string]$UpdaterManifestPath,
    [string]$UpdaterPublicKeyPath,
    [string]$ExpectedVersion,
    [switch]$UseExistingInstallation,
    [switch]$UninstallAfterUpdate,
    [switch]$SkipBuild,
    [switch]$SkipPerformance
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\public-beta-common.ps1"
$repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = [System.IO.Path]::Combine($repo, 'qa-results', 'public-beta') }
$output = Resolve-CallerPath -Path $OutputDirectory -BaseDirectory $InvocationDirectory
if (-not [string]::IsNullOrWhiteSpace($InstallerPath)) { $InstallerPath = Resolve-CallerPath -Path $InstallerPath -BaseDirectory $InvocationDirectory }
if (-not [string]::IsNullOrWhiteSpace($PreviousInstallerPath)) { $PreviousInstallerPath = Resolve-CallerPath -Path $PreviousInstallerPath -BaseDirectory $InvocationDirectory }
if (-not [string]::IsNullOrWhiteSpace($PreviousUpdaterManifestPath)) { $PreviousUpdaterManifestPath = Resolve-CallerPath -Path $PreviousUpdaterManifestPath -BaseDirectory $InvocationDirectory }
if (-not [string]::IsNullOrWhiteSpace($UpdaterManifestPath)) { $UpdaterManifestPath = Resolve-CallerPath -Path $UpdaterManifestPath -BaseDirectory $InvocationDirectory }
if (-not [string]::IsNullOrWhiteSpace($UpdaterPublicKeyPath)) { $UpdaterPublicKeyPath = Resolve-CallerPath -Path $UpdaterPublicKeyPath -BaseDirectory $InvocationDirectory }
$commit = (& git -C $repo rev-parse HEAD).Trim()
$command = ".\scripts\windows\run-public-beta-qa.ps1 -Mode $Mode -OutputDirectory .\qa-results\public-beta"
if (-not [string]::IsNullOrWhiteSpace($InstallerPath)) { $command += " -InstallerPath '.\release\$(Split-Path $InstallerPath -Leaf)'" }
if (-not [string]::IsNullOrWhiteSpace($PreviousInstallerPath)) { $command += " -PreviousInstallerPath '<previous>\$(Split-Path $PreviousInstallerPath -Leaf)'" }
if (-not [string]::IsNullOrWhiteSpace($PreviousUpdaterManifestPath)) { $command += " -PreviousUpdaterManifestPath '<previous>\updater-release-manifest.json'" }
if (-not [string]::IsNullOrWhiteSpace($UpdaterManifestPath)) { $command += " -UpdaterManifestPath '.\release\updater\<version>\updater-release-manifest.json'" }
if (-not [string]::IsNullOrWhiteSpace($UpdaterPublicKeyPath)) { $command += " -UpdaterPublicKeyPath '<external-public-key>'" }
if ($SkipBuild) { $command += ' -SkipBuild' }
if ($SkipPerformance) { $command += ' -SkipPerformance' }
if ($UseExistingInstallation) { $command += ' -UseExistingInstallation' }
if ($UninstallAfterUpdate) { $command += ' -UninstallAfterUpdate' }
$hostFacts = Get-PublicBetaHostFacts

if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
    $candidate = Get-DeskPetReleaseInstaller -ReleaseDirectory ([System.IO.Path]::Combine($repo, 'release'))
    if ($candidate) { $InstallerPath = $candidate.FullName }
}
$versionContext = Resolve-DeskPetVersionContext -RepositoryRoot $repo -ReleaseDirectory ([System.IO.Path]::Combine($repo, 'release')) -InstallerPath $InstallerPath -ExplicitExpectedVersion $ExpectedVersion
$ExpectedVersion = $versionContext.ExpectedVersion
Assert-DeskPetVersionContext -VersionContext $versionContext
function Save-EnvironmentResult {
    param(
        [Parameter(Mandatory)][string]$EnvironmentId,
        [Parameter(Mandatory)][string]$Status,
        [AllowEmptyCollection()][object[]]$Checks,
        [AllowEmptyCollection()][string[]]$Notes,
        [AllowNull()][string]$EvidenceType,
        [AllowNull()][string]$SourceReportStatus,
        [AllowNull()][string]$SourceReportFile,
        [AllowNull()][string]$SourceReportSha256
    )
    $currentArtifactFacts = Get-PublicBetaArtifactFacts $InstallerPath
    $result = New-PublicBetaEnvironmentResult -EnvironmentId $EnvironmentId -Mode $Mode -Status $Status -GitCommit $commit -Command $command -HostFacts $hostFacts -ArtifactFacts $currentArtifactFacts -Checks $Checks -Notes $Notes
    $result['expectedVersion'] = $ExpectedVersion
    if (-not [string]::IsNullOrWhiteSpace($EvidenceType)) { $result['evidenceType'] = $EvidenceType }
    if (-not [string]::IsNullOrWhiteSpace($SourceReportStatus)) { $result['sourceReportStatus'] = $SourceReportStatus }
    if (-not [string]::IsNullOrWhiteSpace($SourceReportFile)) { $result['sourceReportFile'] = $SourceReportFile }
    if (-not [string]::IsNullOrWhiteSpace($SourceReportSha256)) { $result['sourceReportSha256'] = $SourceReportSha256 }
    $directory = [System.IO.Path]::Combine($output, $EnvironmentId)
    if ($WhatIfPreference) {
        Write-Host "Would write environment result: $([System.IO.Path]::Combine($directory, 'environment-result.json'))"
        return
    }
    $path = Write-PublicBetaEnvironmentResult -Result $result -Directory $directory
    Write-Host "Environment result: $path"
}

function Read-ResultRows([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { return @() }
    $parsed = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    return @($parsed)
}

if ($Mode -eq 'PublicBetaAudit') {
    & "$PSScriptRoot\audit-public-beta-readiness.ps1" -ResultsRoot $output -OutputDirectory $output -UpdaterPublicKeyPath $UpdaterPublicKeyPath
    exit $LASTEXITCODE
}

if ($Mode -eq 'Safe') {
    $environmentId = 'current-machine-safe'
    if ($WhatIfPreference) {
        & "$PSScriptRoot\run-qa-suite.ps1" -Mode Safe -OutputDirectory ([System.IO.Path]::Combine($output, $environmentId, 'raw')) -SkipBuild:$SkipBuild -WhatIf
        exit $LASTEXITCODE
    }
    $raw = [System.IO.Path]::Combine($output, $environmentId, 'raw')
    & "$PSScriptRoot\run-qa-suite.ps1" -Mode Safe -OutputDirectory $raw -SkipBuild:$SkipBuild
    $exitCode = $LASTEXITCODE
    $rows = @()
    if ([System.IO.File]::Exists([System.IO.Path]::Combine($raw, 'qa-results.json'))) {
        $parsedRows = Get-Content -LiteralPath ([System.IO.Path]::Combine($raw, 'qa-results.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($parsedRow in $parsedRows) { $rows += $parsedRow }
    }
    $failed = @($rows | Where-Object status -eq 'failed')
    $documentationChecks = @(
        # Keep source literals ASCII-only so Windows PowerShell 5.1 does not depend on the active ANSI code page.
        @{ path='docs\PUBLIC_BETA_RELEASE_NOTES.md'; pattern='NOT_READY' }, @{ path='docs\KNOWN_ISSUES.md'; pattern='NotSigned' },
        @{ path='docs\PRIVACY.md'; pattern='WebView2 Runtime' }, @{ path='docs\INSTALLATION.md'; pattern='SHA256' },
        @{ path='docs\UNINSTALLATION.md'; pattern='APPDATA' }, @{ path='docs\TROUBLESHOOTING.md'; pattern='WebView2' },
        @{ path='docs\SYSTEM_REQUIREMENTS.md'; pattern='x64' }
    )
    $documentationFailures = @($documentationChecks | Where-Object {
        $documentPath = [System.IO.Path]::Combine($repo, [string]$_.path)
        $documentExists = [System.IO.File]::Exists($documentPath)
        $documentMatches = $documentExists -and [System.IO.File]::ReadAllText($documentPath, [System.Text.Encoding]::UTF8).Contains([string]$_.pattern)
        -not $documentMatches
    })
    $documentationFailureNames = @($documentationFailures | ForEach-Object { [string]$_.path })
    $defender = Get-MpComputerStatus -ErrorAction SilentlyContinue
    $defenderStatus = if ($defender -and $defender.AntivirusEnabled -and $defender.RealTimeProtectionEnabled) { 'not_executed' } else { 'blocked' }
    $checks = @(
        [pscustomobject]@{ requirementId='automatic-release'; status=$(if ($exitCode -eq 0 -and -not $failed.Count) {'passed'}else{'failed'}); details="rawChecks=$($rows.Count); failures=$($failed.Count); exitCode=$exitCode" },
        [pscustomobject]@{ requirementId='manifest-hash'; status=$(if (@($rows | Where-Object { $_.name -eq 'Signature, hash and manifest verification' -and $_.status -eq 'passed' }).Count) {'passed'}else{'failed'}); details='Read from Safe QA verification result.' },
        [pscustomobject]@{ requirementId='public-docs'; status=$(if ($documentationFailures.Count) {'failed'}else{'passed'}); details="contentChecks=$($documentationChecks.Count); failures=$($documentationFailures.Count); files=$($documentationFailureNames -join ',')" },
        [pscustomobject]@{ requirementId='defender'; status=$defenderStatus; details="antivirusEnabled=$(if($defender){$defender.AntivirusEnabled}else{'unknown'}); realTimeProtection=$(if($defender){$defender.RealTimeProtectionEnabled}else{'unknown'}); no scan was started" }
    )
    $safeFailed = $failed.Count -or $exitCode -ne 0 -or $documentationFailures.Count
    Save-EnvironmentResult $environmentId $(if ($safeFailed) {'failed'}else{'passed'}) $checks @('This is an automated current-host result; it is not a clean Windows or hardware result.')
    exit $(if ($safeFailed) { 2 } else { 0 })
}

if ($Mode -eq 'CurrentMachine') {
    $environmentId = 'current-machine'
    $raw = [System.IO.Path]::Combine($output, $environmentId, 'raw')
    if ($WhatIfPreference) {
        & "$PSScriptRoot\run-qa-suite.ps1" -Mode CurrentMachine -OutputDirectory $raw -InstallerPath $InstallerPath -ExpectedVersion $ExpectedVersion -UseExistingInstallation:$UseExistingInstallation -SkipBuild:$SkipBuild -SkipPerformance:$SkipPerformance -WhatIf
        exit $LASTEXITCODE
    }
    if (-not $PSCmdlet.ShouldProcess('Current Windows user profile', 'Run install, launch, normal-exit, and uninstall QA')) { exit 0 }
    $exitCode = 1
    $invocationError = $null
    try {
        & "$PSScriptRoot\run-qa-suite.ps1" -Mode CurrentMachine -OutputDirectory $raw -InstallerPath $InstallerPath -ExpectedVersion $ExpectedVersion -UseExistingInstallation:$UseExistingInstallation -SkipBuild:$SkipBuild -SkipPerformance:$SkipPerformance -Confirm:$false
        $exitCode = $LASTEXITCODE
    } catch {
        $invocationError = $_.Exception.Message
    }
    $rows = @(Read-ResultRows ([System.IO.Path]::Combine($raw, 'qa-results.json')))
    $lifecycleFailures = @($rows | Where-Object { $_.status -eq 'failed' -and $_.category -in @('current-machine', 'transaction') })
    $installPassed = if ($UseExistingInstallation) {
        @($rows | Where-Object { $_.name -eq 'Installer execution' -and $_.status -eq 'skipped' }).Count -gt 0
    } else {
        @($rows | Where-Object { $_.name -eq 'Install application' -and $_.status -eq 'passed' }).Count -gt 0
    }
    $uninstallPassed = @($rows | Where-Object { $_.name -eq 'Uninstall application' -and $_.status -eq 'passed' }).Count -gt 0
    $lifecycleStatus = if ($lifecycleFailures.Count -or $invocationError -or $exitCode -ne 0) { 'failed' } elseif ($installPassed -and $uninstallPassed) { 'passed' } else { 'not_executed' }
    $singleInstanceStatus = if (@($rows | Where-Object { $_.name -eq 'Single instance and normal exit' -and $_.status -eq 'passed' }).Count) { 'passed' } elseif (@($rows | Where-Object { $_.name -eq 'Single instance and normal exit' -and $_.status -eq 'failed' }).Count) { 'failed' } else { 'not_executed' }
    $checks = @(
        [pscustomobject]@{ requirementId='current-machine-lifecycle'; status=$lifecycleStatus; details="rawChecks=$($rows.Count); failures=$(@($lifecycleFailures | ForEach-Object name) -join ','); exitCode=$exitCode" },
        [pscustomobject]@{ requirementId='single-instance'; status=$singleInstanceStatus; details='Derived from the real CurrentMachine launch and normal-exit check.' },
        [pscustomobject]@{ requirementId='high-severity-clear'; status=$lifecycleStatus; details='The known high-priority lifecycle issue is cleared only by a complete passing rerun.' }
    )
    $environmentStatus = if ($lifecycleStatus -eq 'failed' -or $singleInstanceStatus -eq 'failed') { 'failed' } elseif ($lifecycleStatus -eq 'passed') { 'passed' } else { 'not_executed' }
    $notes = @('This mode changes the current user installation and requires explicit confirmation.')
    if ($invocationError) { $notes += "Invocation error: $invocationError" }
    Save-EnvironmentResult $environmentId $environmentStatus $checks $notes
    exit $(if ($environmentStatus -eq 'failed') { 2 } else { 0 })
}

if ($Mode -eq 'Sandbox') {
    $detected = & "$PSScriptRoot\detect-test-environments.ps1" | ConvertFrom-Json
    $wsb = [System.IO.Path]::Combine($PSScriptRoot, 'sandbox', 'DeskPetQA.wsb')
    $inputExists = [System.IO.Directory]::Exists('C:\DeskPetQA\Input')
    $resultsExists = [System.IO.Directory]::Exists('C:\DeskPetQA\Results')
    $enabled = [string]$detected.sandbox.state -eq 'Enabled'
    $sandboxStatus = if ($enabled) { 'not_executed' } else { 'blocked' }
    $checks = @(
        [pscustomobject]@{ requirementId='clean-windows-11'; status=$sandboxStatus; details="sandboxState=$($detected.sandbox.state); wsbExists=$([System.IO.File]::Exists($wsb)); inputExists=$inputExists; resultsExists=$resultsExists" },
        [pscustomobject]@{ requirementId='webview2-online'; status=$sandboxStatus; details='Requires a disposable environment with WebView2 absent and networking enabled.' },
        [pscustomobject]@{ requirementId='webview2-offline'; status=$sandboxStatus; details='Requires a disposable environment with WebView2 absent and networking disabled.' }
    )
    $notes = if ($enabled) { @('Sandbox is enabled but was not started. User confirmation is required before launch.') } else { @('Windows Sandbox is disabled. It was not enabled and no restart was requested.') }
    Save-EnvironmentResult 'windows-sandbox' $(if ($enabled) {'not_executed'}else{'blocked'}) $checks $notes
    exit 0
}

if ($Mode -in @('CleanWindows10','CleanWindows11')) {
    $detected = & "$PSScriptRoot\detect-test-environments.ps1" | ConvertFrom-Json
    $vmCount = @($detected.hyperV.virtualMachines).Count
    $requirementId = if ($Mode -eq 'CleanWindows10') { 'clean-windows-10' } else { 'clean-windows-11' }
    $environmentId = if ($Mode -eq 'CleanWindows10') { 'windows-10' } else { 'windows-11' }
    $details = "hyperVVMs=$vmCount; vmware=$($detected.vmware.commandAvailable); virtualBox=$($detected.virtualBox.commandAvailable)"
    $checks = @([pscustomobject]@{ requirementId=$requirementId; status='blocked'; details=$details })
    Save-EnvironmentResult $environmentId 'blocked' $checks @('No VM was started, created, snapshotted, restored, or modified. A matching clean VM must be supplied by the user.')
    exit 0
}

if ($Mode -eq 'Upgrade') {
    if ([string]::IsNullOrWhiteSpace($PreviousInstallerPath) -or [string]::IsNullOrWhiteSpace($InstallerPath)) {
        $checks = @(
            [pscustomobject]@{ requirementId='upgrade-0.1x'; status='blocked'; details='Both previous and current installers are required; same-version reinstall is rejected.' },
            [pscustomobject]@{ requirementId='settings-migration'; status='blocked'; details='Blocked until a real previous-to-current upgrade can run.' },
            [pscustomobject]@{ requirementId='no-duplicates'; status='blocked'; details='Blocked until a real previous-to-current upgrade can run.' }
        )
        Save-EnvironmentResult 'upgrade' 'blocked' $checks @('Supply two different installer artifacts and a disposable Windows environment. No installer was run.') -EvidenceType 'direct_installer_overlay' -SourceReportStatus 'not_executed'
        exit 0
    }
    $upgradeOutput = [System.IO.Path]::Combine($output, 'upgrade')
    if ($WhatIfPreference) {
        & "$PSScriptRoot\upgrade-smoke-test.ps1" -PreviousInstallerPath $PreviousInstallerPath -InstallerPath $InstallerPath -PreviousUpdaterManifestPath $PreviousUpdaterManifestPath -UpdaterManifestPath $UpdaterManifestPath -ExpectedVersion $ExpectedVersion -OutputDirectory $upgradeOutput -WhatIf
        exit $LASTEXITCODE
    }
    if (-not $PSCmdlet.ShouldProcess('Explicit disposable Windows QA environment', 'Run real previous-to-current upgrade and uninstall')) { exit 0 }
    $exitCode = 1
    $invocationError = $null
    try {
        & "$PSScriptRoot\upgrade-smoke-test.ps1" -PreviousInstallerPath $PreviousInstallerPath -InstallerPath $InstallerPath -PreviousUpdaterManifestPath $PreviousUpdaterManifestPath -UpdaterManifestPath $UpdaterManifestPath -ExpectedVersion $ExpectedVersion -OutputDirectory $upgradeOutput -Confirm:$false
        $exitCode = $LASTEXITCODE
    } catch {
        $invocationError = $_.Exception.Message
    }
    $upgradeResultPath = [System.IO.Path]::Combine($upgradeOutput, 'upgrade-result.json')
    $upgradeResult = if ([System.IO.File]::Exists($upgradeResultPath)) { Get-Content -LiteralPath $upgradeResultPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    $upgradeEvidenceType = if ($upgradeResult) { [string](Get-ObjectPropertyValue $upgradeResult 'evidenceType') } else { $null }
    $upgradePassed = $upgradeResult -and $upgradeEvidenceType -eq 'direct_installer_overlay' -and $upgradeResult.status -eq 'passed' -and $exitCode -eq 0 -and -not $invocationError
    $settingsPassed = $upgradePassed -and @($upgradeResult.checks | Where-Object { $_.name -eq 'Settings preserved byte-for-byte' -and $_.passed }).Count -gt 0
    $duplicatesPassed = $upgradePassed -and @($upgradeResult.checks | Where-Object { $_.name -in @('Single uninstall record', 'No duplicate autostart') -and $_.passed }).Count -eq 2
    $checks = @(
        [pscustomobject]@{ requirementId='upgrade-0.1x'; status=$(if($upgradePassed){'passed'}else{'failed'}); details="exitCode=$exitCode; reportPresent=$([bool]$upgradeResult)" },
        [pscustomobject]@{ requirementId='settings-migration'; status=$(if($settingsPassed){'passed'}else{'failed'}); details='Requires a successful byte-for-byte settings preservation assertion.' },
        [pscustomobject]@{ requirementId='no-duplicates'; status=$(if($duplicatesPassed){'passed'}else{'failed'}); details='Requires one uninstall record and no duplicate autostart entry.' }
    )
    $notes = @('This evidence is a direct NSIS installer overlay compatibility test. It is not application updater end-to-end evidence.')
    if ($invocationError) { $notes += "Invocation error: $invocationError" }
    Save-EnvironmentResult 'upgrade' $(if($upgradePassed -and $settingsPassed -and $duplicatesPassed){'passed'}else{'failed'}) $checks $notes -EvidenceType 'direct_installer_overlay' -SourceReportStatus $(if($upgradeResult){[string]$upgradeResult.status}else{'missing'})
    exit $(if($upgradePassed -and $settingsPassed -and $duplicatesPassed){0}else{2})
}

if ($Mode -eq 'ApplicationUpdater') {
    $environmentId = 'application-updater'
    if ([string]::IsNullOrWhiteSpace($PreviousInstallerPath) -or [string]::IsNullOrWhiteSpace($InstallerPath)) {
        $checks = @([pscustomobject]@{
            requirementId='application-updater-e2e'; status='blocked'
            details='Both version A and version B installer artifacts are required. Version B is reference-only and will not be started by QA.'
        })
        Save-EnvironmentResult $environmentId 'blocked' $checks @('No installer was run.') -EvidenceType 'application_updater_e2e' -SourceReportStatus 'not_executed'
        exit 0
    }
    $applicationUpdaterOutput = [System.IO.Path]::Combine($output, $environmentId, 'raw')
    $applicationUpdaterParameters = @{
        PreviousInstallerPath=$PreviousInstallerPath
        InstallerPath=$InstallerPath
        PreviousUpdaterManifestPath=$PreviousUpdaterManifestPath
        UpdaterManifestPath=$UpdaterManifestPath
        UpdaterPublicKeyPath=$UpdaterPublicKeyPath
        ExpectedVersion=$ExpectedVersion
        OutputDirectory=$applicationUpdaterOutput
        TimeoutSeconds=600
        UninstallAfterUpdate=$UninstallAfterUpdate
    }
    if ($WhatIfPreference) {
        & "$PSScriptRoot\application-updater-smoke-test.ps1" @applicationUpdaterParameters -WhatIf
        exit $LASTEXITCODE
    }
    $resultPath = [System.IO.Path]::Combine($applicationUpdaterOutput, 'application-updater-result.json')
    $relativeRawReport = [System.IO.Path]::Combine('raw', 'application-updater-result.json')
    if (-not $PSCmdlet.ShouldProcess('Explicit disposable Windows QA environment', 'Install version A only and monitor a user-triggered in-app update to version B')) {
        $declinedResult = [ordered]@{
            schemaVersion=1; evidenceType='application_updater_e2e'; phase='confirmation-declined'; status='not_executed'; whatIf=$false
            startedAtUtc=[DateTime]::UtcNow.ToString('o'); finishedAtUtc=[DateTime]::UtcNow.ToString('o')
            currentInstallerExecutionAllowed=$false; endpointCandidateBinding=$false
            uiPendingTargetObserved=$false; uiConfirmedTargetObserved=$false; uiPendingClearedAfterConfirmation=$false
            installerExecutions=@(); checks=@(); failure=$null
        }
        Write-PublicBetaAtomicJson -InputObject $declinedResult -LiteralPath $resultPath -Depth 12
        $declinedHash = (Get-FileHash -LiteralPath $resultPath -Algorithm SHA256).Hash
        $declinedChecks = @([pscustomobject]@{ requirementId='application-updater-e2e'; status='not_executed'; details='Operator declined the real application updater run.' })
        Save-EnvironmentResult $environmentId 'not_executed' $declinedChecks @('Operator declined confirmation; no installer was run.') `
            -EvidenceType 'application_updater_e2e' -SourceReportStatus 'not_executed' -SourceReportFile $relativeRawReport -SourceReportSha256 $declinedHash
        exit 0
    }
    $exitCode = 1
    $invocationError = $null
    try {
        & "$PSScriptRoot\application-updater-smoke-test.ps1" @applicationUpdaterParameters -Confirm:$false
        $exitCode = $LASTEXITCODE
    } catch {
        $invocationError = $_.Exception.Message
    }
    $rawReadError = $null
    $applicationUpdaterResult = $null
    if ([System.IO.File]::Exists($resultPath)) {
        try { $applicationUpdaterResult = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { $rawReadError = ConvertTo-PublicBetaSafeFailureMessage -Message $_.Exception.Message -RepositoryRoot $repo }
    }
    $rawReportHash = if ([System.IO.File]::Exists($resultPath)) { (Get-FileHash -LiteralPath $resultPath -Algorithm SHA256).Hash } else { $null }
    $sourceStatus = if ($applicationUpdaterResult) { [string](Get-ObjectPropertyValue $applicationUpdaterResult 'status') } else { 'missing' }
    $sourceEvidenceType = if ($applicationUpdaterResult) { [string](Get-ObjectPropertyValue $applicationUpdaterResult 'evidenceType') } else { $null }
    $rawRoles = if ($applicationUpdaterResult) { @((Get-ObjectPropertyValue $applicationUpdaterResult 'cryptographicallyVerifiedArtifactRoles') | ForEach-Object { [string]$_ } | Sort-Object -Unique) } else { @() }
    $rawExecutions = if ($applicationUpdaterResult) { @((Get-ObjectPropertyValue $applicationUpdaterResult 'installerExecutions')) } else { @() }
    $rawApplicationEvidence = $applicationUpdaterResult -and
        (Test-DeskPetSchemaVersionOne -InputObject $applicationUpdaterResult) -and
        [string](Get-ObjectPropertyValue $applicationUpdaterResult 'phase') -eq 'completed' -and
        (Get-ObjectPropertyValue $applicationUpdaterResult 'whatIf') -is [bool] -and -not [bool](Get-ObjectPropertyValue $applicationUpdaterResult 'whatIf') -and
        [string](Get-ObjectPropertyValue $applicationUpdaterResult 'finalProbeStatus') -eq 'passed' -and
        $null -eq (Get-ObjectPropertyValue $applicationUpdaterResult 'failure') -and
        (Get-ObjectPropertyValue $applicationUpdaterResult 'endpointCandidateBinding') -is [bool] -and [bool](Get-ObjectPropertyValue $applicationUpdaterResult 'endpointCandidateBinding') -and
        (Get-ObjectPropertyValue $applicationUpdaterResult 'uiPendingTargetObserved') -is [bool] -and [bool](Get-ObjectPropertyValue $applicationUpdaterResult 'uiPendingTargetObserved') -and
        (Get-ObjectPropertyValue $applicationUpdaterResult 'uiConfirmedTargetObserved') -is [bool] -and [bool](Get-ObjectPropertyValue $applicationUpdaterResult 'uiConfirmedTargetObserved') -and
        (Get-ObjectPropertyValue $applicationUpdaterResult 'uiPendingClearedAfterConfirmation') -is [bool] -and [bool](Get-ObjectPropertyValue $applicationUpdaterResult 'uiPendingClearedAfterConfirmation') -and
        (Get-ObjectPropertyValue $applicationUpdaterResult 'uiOrderedTransitionObserved') -is [bool] -and [bool](Get-ObjectPropertyValue $applicationUpdaterResult 'uiOrderedTransitionObserved') -and
        $rawExecutions.Count -eq 1 -and [string](Get-ObjectPropertyValue $rawExecutions[0] 'role') -eq 'version_a' -and
        $rawRoles.Count -eq 2 -and $rawRoles -contains 'version_a' -and $rawRoles -contains 'version_b'
    $applicationUpdaterPassed = $applicationUpdaterResult -and $sourceEvidenceType -eq 'application_updater_e2e' -and $sourceStatus -eq 'passed' -and $rawApplicationEvidence -and $exitCode -eq 0 -and -not $invocationError
    $settingsPassed = $applicationUpdaterPassed -and @($applicationUpdaterResult.checks | Where-Object { $_.name -eq 'Settings preserved' -and $_.passed }).Count -eq 1
    $characterPassed = $applicationUpdaterPassed -and @($applicationUpdaterResult.checks | Where-Object { $_.name -eq 'Character selection preserved' -and $_.passed }).Count -eq 1
    $duplicatesPassed = $applicationUpdaterPassed -and @($applicationUpdaterResult.checks | Where-Object { $_.name -in @('Single uninstall record','No duplicate autostart') -and $_.passed }).Count -eq 2
    $checks = @(
        [pscustomobject]@{ requirementId='application-updater-e2e'; status=$(if($applicationUpdaterPassed){'passed'}else{'failed'}); details="evidenceType=$sourceEvidenceType; sourceStatus=$sourceStatus; exitCode=$exitCode; reportPresent=$([bool]$applicationUpdaterResult)" },
        [pscustomobject]@{ requirementId='settings-migration'; status=$(if($settingsPassed -and $characterPassed){'passed'}else{'failed'}); details='Stable settings fields and character selection must both survive the in-app update.' },
        [pscustomobject]@{ requirementId='no-duplicates'; status=$(if($duplicatesPassed){'passed'}else{'failed'}); details='Requires one uninstall record and no duplicate autostart entry after the in-app update.' }
    )
    $environmentStatus = if ($applicationUpdaterPassed -and $settingsPassed -and $characterPassed -and $duplicatesPassed) { 'passed' } else { 'failed' }
    $notes = @('The QA script starts only version A. Version B must be discovered, downloaded, and installed by the application updater UI.')
    if ($invocationError) {
        $safeInvocationError = ConvertTo-PublicBetaSafeFailureMessage -Message $invocationError -RepositoryRoot $repo
        $notes += "Invocation error: $safeInvocationError"
    }
    if ($rawReadError) { $notes += "Raw report parse error: $rawReadError" }
    Save-EnvironmentResult $environmentId $environmentStatus $checks $notes -EvidenceType 'application_updater_e2e' -SourceReportStatus $sourceStatus `
        -SourceReportFile $relativeRawReport -SourceReportSha256 $rawReportHash
    exit $(if($environmentStatus -eq 'passed'){0}else{2})
}

if ($Mode -eq 'Performance') {
    $performance = [System.IO.Path]::Combine($output, 'performance')
    if ($SkipPerformance) { Write-Host 'Performance capture skipped by -SkipPerformance.'; exit 0 }
    if ($WhatIfPreference) {
        Write-Host "Would capture 15 minutes to $performance. This preview does not claim an eight-hour pass."
        exit 0
    }
    if (-not $PSCmdlet.ShouldProcess("Current $script:ProcessName process", 'Capture 15 minutes of performance data')) { exit 0 }
    [System.IO.Directory]::CreateDirectory($performance) | Out-Null
    $csv = [System.IO.Path]::Combine($performance, 'performance.csv')
    $exitCode = 1
    $invocationError = $null
    try {
        $LASTEXITCODE = 0
        & "$PSScriptRoot\monitor-process.ps1" -DurationMinutes 15 -IntervalSeconds 10 -OutputPath $csv
        $exitCode = [int]$LASTEXITCODE
        if ($exitCode -eq 0) {
            $LASTEXITCODE = 0
            & "$PSScriptRoot\analyze-performance.ps1" -InputPath $csv -OutputPath ([System.IO.Path]::Combine($performance, 'performance-summary.md')) -JsonOutputPath ([System.IO.Path]::Combine($performance, 'performance-analysis.json'))
            $exitCode = [int]$LASTEXITCODE
        }
    } catch {
        $invocationError = $_.Exception.Message
    }
    $capturePassed = $exitCode -eq 0 -and -not $invocationError
    $checks = @(
        [pscustomobject]@{ requirementId='performance-short'; status=$(if($capturePassed){'passed'}else{'failed'}); details="15-minute capture; exitCode=$exitCode" },
        [pscustomobject]@{ requirementId='stability-8h'; status='not_executed'; details='A 15-minute capture does not satisfy the eight-hour requirement.' }
    )
    $notes = @('Review trends and responsiveness manually; capture duration alone is not a stability pass.')
    if ($invocationError) { $notes += "Invocation error: $invocationError" }
    Save-EnvironmentResult 'performance' $(if($capturePassed){'passed'}else{'failed'}) $checks $notes
    exit $(if($capturePassed){0}else{2})
}
