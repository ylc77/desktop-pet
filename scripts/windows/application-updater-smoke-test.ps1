[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$PreviousInstallerPath,
    [Parameter(Mandatory)][string]$InstallerPath,
    [string]$PreviousUpdaterManifestPath,
    [string]$UpdaterManifestPath,
    [string]$UpdaterPublicKeyPath,
    [string]$ExpectedVersion,
    [string]$OutputDirectory,
    [ValidateRange(30, 1800)][int]$TimeoutSeconds = 600,
    [switch]$UninstallAfterUpdate
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\public-beta-common.ps1"

$repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
$fallbackOutput = [System.IO.Path]::Combine(
    $repo, 'qa-results', 'public-beta', 'application-updater-failures', [Guid]::NewGuid().ToString('N')
)
$output = $null
$reportPath = $null
$settingsPath = $null
$previousInstaller = $null
$currentInstallerReference = $null
$state = $null
$caughtError = $null

function Invoke-VersionAInstaller {
    param([Parameter(Mandatory)][string]$Path)
    $process = Start-Process -FilePath $Path -ArgumentList @('/S') -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        throw "Version A installer timed out after $TimeoutSeconds seconds."
    }
    if ($process.ExitCode -ne 0) { throw "Version A installer failed with exit code $($process.ExitCode)." }
}

function Wait-VersionAInstallation {
    param([Parameter(Mandatory)][string]$Version)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 60) {
        $records = @(Get-DeskPetInstallRecords)
        $selection = Select-DeskPetInstallRecord -Records $records -ExpectedVersion $Version
        if ($selection.SelectedRecord) { return $selection }
        Start-Sleep -Milliseconds 500
    }
    throw "Version A installer completed, but no usable $Version installation appeared within 60 seconds."
}

function Wait-VersionAProcess {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 30) {
        $processes = @(Get-DeskPetRunningProcesses)
        if ($processes.Count) { return @($processes) }
        Start-Sleep -Milliseconds 500
    }
    throw 'Version A did not start within 30 seconds.'
}

try {
    $state = [ordered]@{
        schemaVersion=1
        evidenceType='application_updater_e2e'
        phase='initialization'
        status='not_executed'
        whatIf=[bool]$WhatIfPreference
        startedAtUtc=[DateTime]::UtcNow.ToString('o')
        currentInstallerExecutionAllowed=$false
        endpointCandidateBinding=$false
        remoteMetadataFetchPlanned=$true
        uiPendingTargetObserved=$false
        uiConfirmedTargetObserved=$false
        uiPendingClearedAfterConfirmation=$false
        uiOrderedTransitionObserved=$false
        installerExecutions=@()
        checks=@()
        failure=$null
        recoveryCommands=@('.\scripts\windows\uninstall-smoke-test.ps1 -WhatIf')
    }
    try {
        if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
            $OutputDirectory = [System.IO.Path]::Combine($repo, 'qa-results', 'public-beta', 'application-updater')
        }
        $output = Resolve-CallerPath -Path $OutputDirectory -BaseDirectory $InvocationDirectory
        [void][System.IO.Directory]::CreateDirectory($output)
        $reportPath = [System.IO.Path]::Combine($output, 'application-updater-result.json')
    } catch {
        $state.phase = 'output-initialization'
        $output = $fallbackOutput
        [void][System.IO.Directory]::CreateDirectory($output)
        $reportPath = [System.IO.Path]::Combine($output, 'application-updater-result.json')
        throw 'The requested QA output directory could not be initialized; a safe fallback report was selected.'
    }

    $state.phase = 'path-validation'
    $previousInstaller = Resolve-CallerPath -Path $PreviousInstallerPath -BaseDirectory $InvocationDirectory
    $currentInstallerReference = Resolve-CallerPath -Path $InstallerPath -BaseDirectory $InvocationDirectory
    if (-not [string]::IsNullOrWhiteSpace($PreviousUpdaterManifestPath)) {
        $PreviousUpdaterManifestPath = Resolve-CallerPath -Path $PreviousUpdaterManifestPath -BaseDirectory $InvocationDirectory
    }
    if (-not [string]::IsNullOrWhiteSpace($UpdaterManifestPath)) {
        $UpdaterManifestPath = Resolve-CallerPath -Path $UpdaterManifestPath -BaseDirectory $InvocationDirectory
    }
    if (-not [string]::IsNullOrWhiteSpace($UpdaterPublicKeyPath)) {
        $UpdaterPublicKeyPath = Resolve-CallerPath -Path $UpdaterPublicKeyPath -BaseDirectory $InvocationDirectory
    }
    $settingsPath = [System.IO.Path]::Combine($env:APPDATA, $script:AppIdentifier, 'settings.json')
    $state['previousInstallerFile'] = [System.IO.Path]::GetFileName($previousInstaller)
    $state['currentInstallerReferenceFile'] = [System.IO.Path]::GetFileName($currentInstallerReference)
    $state.phase = 'validation'
    Assert-FileExists $previousInstaller 'Version A NSIS installer'
    Assert-FileExists $currentInstallerReference 'Version B NSIS installer reference'
    $currentVersionContext = Resolve-DeskPetVersionContext -RepositoryRoot $repo `
        -ReleaseDirectory ([System.IO.Path]::Combine($repo, 'release')) `
        -InstallerPath $currentInstallerReference -ExplicitExpectedVersion $ExpectedVersion
    Assert-DeskPetVersionContext -VersionContext $currentVersionContext
    $currentVersion = $currentVersionContext.ExpectedVersion
    $previousVersion = Get-DeskPetInstallerVersion -InstallerPath $previousInstaller
    $state['previousVersion'] = $previousVersion
    $state['currentVersion'] = $currentVersion

    if ([string]::IsNullOrWhiteSpace($PreviousUpdaterManifestPath)) {
        $PreviousUpdaterManifestPath = Get-DeskPetUpdaterManifestPath -ReleaseDirectory ([System.IO.Path]::Combine($repo, 'release')) -Version $previousVersion
    }
    if ([string]::IsNullOrWhiteSpace($UpdaterManifestPath)) {
        $UpdaterManifestPath = Get-DeskPetUpdaterManifestPath -ReleaseDirectory ([System.IO.Path]::Combine($repo, 'release')) -Version $currentVersion
    }
    Assert-FileExists $PreviousUpdaterManifestPath 'Version A updater release manifest'
    Assert-FileExists $UpdaterManifestPath 'Version B updater release manifest'
    $previousManifest = Get-Content -LiteralPath $PreviousUpdaterManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $currentManifest = Get-Content -LiteralPath $UpdaterManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not (Test-DeskPetSchemaVersionOne -InputObject $previousManifest) -or
        -not (Test-DeskPetSchemaVersionOne -InputObject $currentManifest)) {
        throw 'Updater release manifest schemaVersion must be the JSON integer 1.'
    }
    $previousManifestVersion = [string](Get-ObjectPropertyValue $previousManifest 'version')
    $currentManifestVersion = [string](Get-ObjectPropertyValue $currentManifest 'version')
    if ($previousManifestVersion -ne $previousVersion -or $currentManifestVersion -ne $currentVersion) {
        throw "Updater manifest version mismatch: AInstaller=$previousVersion; AManifest=$previousManifestVersion; BInstaller=$currentVersion; BManifest=$currentManifestVersion"
    }
    Assert-DeskPetUpgradeIdentity -PreviousVersion $previousVersion -CurrentVersion $currentVersion `
        -PreviousIdentifier ([string](Get-ObjectPropertyValue $previousManifest 'identifier')) `
        -CurrentIdentifier ([string](Get-ObjectPropertyValue $currentManifest 'identifier')) `
        -PreviousPublicKeyFingerprint ([string](Get-ObjectPropertyValue $previousManifest 'publicKeyFingerprint')) `
        -CurrentPublicKeyFingerprint ([string](Get-ObjectPropertyValue $currentManifest 'publicKeyFingerprint'))
    $updaterPlatform = [string](Get-ObjectPropertyValue $currentManifest 'platform')
    if ([string]::IsNullOrWhiteSpace($updaterPlatform)) { $updaterPlatform = 'windows-x86_64' }
    $previousPlatform = [string](Get-ObjectPropertyValue $previousManifest 'platform')
    if (-not [string]::IsNullOrWhiteSpace($previousPlatform) -and $previousPlatform -ne $updaterPlatform) {
        throw 'Version A and version B updater platforms do not match.'
    }
    $currentDownloadUrl = [string](Get-ObjectPropertyValue $currentManifest 'downloadUrl')
    $previousHash = (Get-FileHash -LiteralPath $previousInstaller -Algorithm SHA256).Hash
    $currentHash = (Get-FileHash -LiteralPath $currentInstallerReference -Algorithm SHA256).Hash
    if ($previousHash -eq $currentHash) { throw 'Version A and version B installers are identical.' }
    if ([string](Get-ObjectPropertyValue $previousManifest 'artifactSha256') -ne $previousHash -or
        [string](Get-ObjectPropertyValue $currentManifest 'artifactSha256') -ne $currentHash) {
        throw 'An installer hash does not match its updater release manifest.'
    }
    foreach ($manifest in @($previousManifest, $currentManifest)) {
        $dirtyValue = Get-ObjectPropertyValue $manifest 'dirtyWorktree'
        if ($dirtyValue -isnot [System.Boolean] -or [bool]$dirtyValue) {
            throw 'Application updater QA requires a strict clean-worktree Boolean in both release manifests.'
        }
    }
    $endpoint = [string](Get-ObjectPropertyValue $previousManifest 'endpoint')
    $endpointUri = $null
    if (-not [Uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$endpointUri) -or $endpointUri.Scheme -ne 'https') {
        throw 'Version A updater endpoint is not an absolute HTTPS URL.'
    }
    if ([string]::IsNullOrWhiteSpace($UpdaterPublicKeyPath)) {
        if (-not $WhatIfPreference) { throw 'Real application updater QA requires -UpdaterPublicKeyPath.' }
    } else {
        Assert-FileExists $UpdaterPublicKeyPath 'External updater public key'
        $publicKeyFingerprint = Get-UpdaterPublicKeyFingerprint -PublicKeyPath $UpdaterPublicKeyPath
        if ($publicKeyFingerprint -ne [string](Get-ObjectPropertyValue $currentManifest 'publicKeyFingerprint')) {
            throw 'The external updater public key does not match the A/B release manifests.'
        }
        $artifactSets = @(
            Resolve-PublicBetaUpdaterArtifactSet -Role 'version_a' -Manifest $previousManifest `
                -ManifestPath $PreviousUpdaterManifestPath -ExpectedInstallerSha256 $previousHash
            Resolve-PublicBetaUpdaterArtifactSet -Role 'version_b' -Manifest $currentManifest `
                -ManifestPath $UpdaterManifestPath -ExpectedInstallerSha256 $currentHash
        )
        Assert-PublicBetaUpdaterArtifactSignatures -ArtifactSets $artifactSets -PublicKeyPath $UpdaterPublicKeyPath
        $state['publicKeyFingerprint'] = $publicKeyFingerprint
        $state['cryptographicallyVerifiedArtifactRoles'] = @($artifactSets | ForEach-Object { [string]$_.Role })
    }
    $state['endpointHost'] = $endpointUri.DnsSafeHost
    $state['updaterPlatform'] = $updaterPlatform
    $state['previousInstallerSha256'] = $previousHash
    $state['currentInstallerSha256'] = $currentHash

    if ($WhatIfPreference) {
        $state.phase = 'preview'
        $state.checks = @(
            [ordered]@{ name='Preview only'; passed=$true; details='No installer, application, updater, or uninstaller was started.' },
            [ordered]@{ name='Version B installer execution prohibited'; passed=$true; details='Version B is an artifact reference only; the application must download and install it.' },
            [ordered]@{ name='Remote endpoint candidate binding planned'; passed=$true; details='Real mode will fetch version A endpoint metadata and bind it to local version B; WhatIf does not use the network.' }
        )
        Write-Host "Application updater preview: A=$([System.IO.Path]::GetFileName($previousInstaller)); B-reference=$([System.IO.Path]::GetFileName($currentInstallerReference)); output=$output"
        Write-Host "Would install only version A ($previousVersion), start A, wait for the operator to trigger the updater UI, and monitor A -> B ($currentVersion) for at most $TimeoutSeconds seconds."
        Write-Host 'The script never starts the version B installer. -UninstallAfterUpdate is explicit and applies only after a passing in-app update.'
        Write-Host "Would fetch and validate latest.json from HTTPS host $($endpointUri.DnsSafeHost) only after real-run confirmation."
    } else {
        if ($env:DESK_PET_QA_CLEAN_ENVIRONMENT -ne '1') {
            throw 'Real application updater QA requires DESK_PET_QA_CLEAN_ENVIRONMENT=1 in an explicitly designated disposable environment.'
        }
        if (-not $PSCmdlet.ShouldProcess('Disposable Windows QA environment', 'Install version A only, monitor an operator-triggered in-app update to B, and verify preservation')) {
            $state.phase = 'confirmation-declined'
        } else {
            $state.phase = 'validate-remote-endpoint'
            $versionBArtifactSet = @($artifactSets | Where-Object Role -eq 'version_b')[0]
            $remoteBinding = Invoke-PublicBetaRemoteLatestBinding -Endpoint $endpoint -CurrentVersion $previousVersion `
                -ExpectedVersion $currentVersion -Platform $updaterPlatform -ExpectedDownloadUrl $currentDownloadUrl `
                -ArtifactPath $versionBArtifactSet.ArtifactPath -SignaturePath $versionBArtifactSet.SignaturePath `
                -PublicKeyPath $UpdaterPublicKeyPath -RepositoryRoot $repo
            $state.endpointCandidateBinding = [bool]$remoteBinding.Bound
            $state['remoteLatestSha256'] = [string]$remoteBinding.LatestSha256
            $state['remoteMetadataHost'] = [string]$remoteBinding.FinalMetadataHost
            $state['remoteArtifactHost'] = [string]$remoteBinding.ArtifactHost
            $state['remoteArtifactFile'] = [string]$remoteBinding.ArtifactFile
            $state['remoteArtifactSizeBytes'] = [long]$remoteBinding.ArtifactSizeBytes
            $state['remoteArtifactSignatureSha256'] = [string]$remoteBinding.SignatureSha256
            $existingRecords = @(Get-DeskPetInstallRecords -IncludeLegacy)
            if ($existingRecords.Count) { throw "The disposable environment is not clean; found $($existingRecords.Count) existing install record(s)." }
            $state.phase = 'install-version-a'
            $state.installerExecutions += [ordered]@{ role='version_a'; file=[System.IO.Path]::GetFileName($previousInstaller); sha256=$previousHash }
            Invoke-VersionAInstaller -Path $previousInstaller
            $versionASelection = Wait-VersionAInstallation -Version $previousVersion
            $versionAExecutable = [string]$versionASelection.ExecutablePath
            $state.phase = 'launch-version-a'
            Start-Process -FilePath $versionAExecutable | Out-Null
            $versionAProcesses = @(Wait-VersionAProcess)
            $initialProcessIds = @($versionAProcesses | ForEach-Object { [int]$_.Id })

            Write-Host 'In version A, set non-sensitive preferences and select/import a QA character. Do not start the update yet.'
            Write-Host 'Press Enter when ready; monitoring will begin. Then use About/Update in version A to check, download, and install version B.'
            Read-Host | Out-Null
            $beforeSettings = Get-DeskPetPreservedSettingsSnapshot -Path $settingsPath
            if (-not [string]::IsNullOrWhiteSpace($beforeSettings.PendingUpdateVersion) -or
                $beforeSettings.LastConfirmedUpdateVersion -eq $currentVersion) {
                throw 'The pre-update settings do not provide a clean updater UI confirmation baseline.'
            }
            $beforeAutostart = Get-PublicBetaAutostartSnapshot -Entries @(Get-DeskPetRunEntries) -ExpectedExecutablePath $versionAExecutable
            $beforeStartMenu = Get-PublicBetaStartMenuSnapshot -Entries @(Get-DeskPetStartMenuEntries) -ExpectedExecutablePath $versionAExecutable
            $beforeCharacter = Get-PublicBetaInstalledCharacterSnapshot -CharacterId $beforeSettings.CharacterId -SkinId $beforeSettings.SkinId
            $beforeAutostartConsistent = if ($beforeSettings.Autostart) { $beforeAutostart.Count -eq 1 } else { $beforeAutostart.Count -eq 0 }
            if (-not $beforeAutostartConsistent -or -not $beforeAutostart.AllTargetExpectedExecutable) {
                throw 'The pre-update autostart state is inconsistent with settings or does not target version A.'
            }
            if ($beforeStartMenu.Count -ne 1 -or -not $beforeStartMenu.AllTargetExpectedExecutable) {
                throw 'The pre-update Start menu shortcut is missing, duplicated, or targets the wrong executable.'
            }
            $state.phase = 'waiting-for-application-updater'
            $probe = {
                $records = @(Get-DeskPetInstallRecords)
                $processes = @(Get-DeskPetRunningProcesses)
                $pendingUpdateVersion = $null
                $lastConfirmedUpdateVersion = $null
                try {
                    if ([System.IO.File]::Exists($settingsPath)) {
                        $probeSettings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
                        $pendingUpdateVersion = [string](Get-ObjectPropertyValue $probeSettings 'pendingUpdateVersion')
                        $lastConfirmedUpdateVersion = [string](Get-ObjectPropertyValue $probeSettings 'lastConfirmedUpdateVersion')
                    }
                } catch { }
                [pscustomobject]@{
                    Versions=@($records | ForEach-Object { [string](Get-ObjectPropertyValue $_ 'DisplayVersion') })
                    ProcessIds=@($processes | ForEach-Object { [int]$_.Id })
                    RecordCount=$records.Count
                    PendingUpdateVersion=$pendingUpdateVersion
                    LastConfirmedUpdateVersion=$lastConfirmedUpdateVersion
                }
            }
            $transition = Wait-PublicBetaApplicationUpdaterTransition -PreviousVersion $previousVersion -CurrentVersion $currentVersion `
                -InitialProcessIds $initialProcessIds -TimeoutSeconds $TimeoutSeconds -PollIntervalMilliseconds 250 -Probe $probe
            $state.uiPendingTargetObserved = [bool]$transition.PendingTargetObserved
            $state.uiConfirmedTargetObserved = [bool]$transition.ConfirmedTargetObserved
            $state.uiPendingClearedAfterConfirmation = [bool]$transition.PendingClearedAfterConfirmation
            $state.uiOrderedTransitionObserved = [bool]$transition.OrderedTransitionObserved
            $recordsAfter = @(Get-DeskPetInstallRecords)
            $currentSelection = Select-DeskPetInstallRecord -Records $recordsAfter -ExpectedVersion $currentVersion
            $currentProcesses = @(Get-DeskPetRunningProcesses)
            $currentExecutablePath = [string]$currentSelection.ExecutablePath
            $newProcessPathMatches = $false
            foreach ($currentProcess in $currentProcesses) {
                if ($transition.NewProcessIds -notcontains [int]$currentProcess.Id) { continue }
                try {
                    $runningPath = [string]$currentProcess.Path
                    if (-not [string]::IsNullOrWhiteSpace($runningPath) -and
                        [string]::Equals([System.IO.Path]::GetFullPath($runningPath), [System.IO.Path]::GetFullPath($currentExecutablePath), [StringComparison]::OrdinalIgnoreCase)) {
                        $newProcessPathMatches = $true
                    }
                } catch { }
            }
            $afterSettings = Get-DeskPetPreservedSettingsSnapshot -Path $settingsPath
            $afterAutostart = Get-PublicBetaAutostartSnapshot -Entries @(Get-DeskPetRunEntries) -ExpectedExecutablePath $currentExecutablePath
            $afterStartMenu = Get-PublicBetaStartMenuSnapshot -Entries @(Get-DeskPetStartMenuEntries) -ExpectedExecutablePath $currentExecutablePath
            $afterCharacter = Get-PublicBetaInstalledCharacterSnapshot -CharacterId $afterSettings.CharacterId -SkinId $afterSettings.SkinId
            $settingsPreserved = $beforeSettings.Fingerprint -eq $afterSettings.Fingerprint
            $characterPreserved = $beforeSettings.CharacterId -eq $afterSettings.CharacterId -and $beforeSettings.SkinId -eq $afterSettings.SkinId
            $characterPackagePreserved = $beforeCharacter.Fingerprint -eq $afterCharacter.Fingerprint -and $beforeCharacter.FileCount -eq $afterCharacter.FileCount
            $autostartPreserved = $beforeAutostart.Fingerprint -eq $afterAutostart.Fingerprint -and
                $beforeAutostart.Count -eq $afterAutostart.Count -and $afterAutostart.AllTargetExpectedExecutable
            $afterAutostartConsistent = if ($afterSettings.Autostart) { $afterAutostart.Count -eq 1 } else { $afterAutostart.Count -eq 0 }
            $startMenuPreserved = $beforeStartMenu.Fingerprint -eq $afterStartMenu.Fingerprint -and
                $beforeStartMenu.Count -eq $afterStartMenu.Count -and $afterStartMenu.Count -eq 1 -and $afterStartMenu.AllTargetExpectedExecutable
            $state.checks = @(
                [ordered]@{ name='Version A updater artifact cryptographically verified'; passed=@($state.cryptographicallyVerifiedArtifactRoles) -contains 'version_a'; details='The version A artifact and detached signature were verified with the external production public key.' },
                [ordered]@{ name='Version B updater artifact cryptographically verified'; passed=@($state.cryptographicallyVerifiedArtifactRoles) -contains 'version_b'; details='The version B artifact and detached signature were verified with the external production public key.' },
                [ordered]@{ name='Application updater transition'; passed=[bool]$transition.Complete; details="elapsedMilliseconds=$($transition.ElapsedMilliseconds); attempts=$($transition.Attempts)" },
                [ordered]@{ name='Remote endpoint candidate binding'; passed=[bool]$state.endpointCandidateBinding; details='Remote latest.json version, URL, size and signature were bound to the locally verified version B artifact.' },
                [ordered]@{ name='Version B installer was not invoked by QA'; passed=$state.installerExecutions.Count -eq 1 -and $state.installerExecutions[0].role -eq 'version_a'; details='Only the version A bootstrap installer is recorded.' },
                [ordered]@{ name='Updater UI pending target observed'; passed=[bool]$transition.PendingTargetObserved; details='pendingUpdateVersion was observed as version B while version A performed the update.' },
                [ordered]@{ name='Updater UI target confirmed after restart'; passed=[bool]$transition.ConfirmedTargetObserved -and [bool]$transition.PendingClearedAfterConfirmation; details='lastConfirmedUpdateVersion became version B and pendingUpdateVersion was cleared.' },
                [ordered]@{ name='Updater UI ordered pending-to-confirmed transition'; passed=[bool]$transition.OrderedTransitionObserved; details="pendingAttempt=$($transition.PendingObservedAttempt); restartAttempt=$($transition.RestartObservedAttempt); confirmationAttempt=$($transition.ConfirmationObservedAttempt)" },
                [ordered]@{ name='Version A observed before update'; passed=[bool]$transition.PreviousVersionObserved; details="version=$previousVersion" },
                [ordered]@{ name='Version B installation record'; passed=[bool]$currentSelection.SelectedRecord; details="expected=$currentVersion; records=$($recordsAfter.Count)" },
                [ordered]@{ name='Old version process exited'; passed=[bool]$transition.OldProcessesExited; details="oldPidCount=$($initialProcessIds.Count)" },
                [ordered]@{ name='New version process started'; passed=$transition.NewProcessIds.Count -gt 0; details="newPidCount=$($transition.NewProcessIds.Count); registryVersion=$currentVersion" },
                [ordered]@{ name='New process uses version B executable'; passed=$newProcessPathMatches; details='Process path matched the selected version B install record.' },
                [ordered]@{ name='Single uninstall record'; passed=$recordsAfter.Count -eq 1; details="count=$($recordsAfter.Count)" },
                [ordered]@{ name='Settings preserved'; passed=$settingsPreserved; details='Fingerprint of stable, non-updater settings fields.' },
                [ordered]@{ name='Character selection preserved'; passed=$characterPreserved; details='characterId and skinId matched without logging their values.' },
                [ordered]@{ name='Imported character package preserved and loadable'; passed=$characterPackagePreserved; details="files=$($afterCharacter.FileCount); manifest, frame index and PNG frame paths were validated." },
                [ordered]@{ name='Autostart state preserved'; passed=$autostartPreserved -and $afterAutostartConsistent; details="before=$($beforeAutostart.Count); after=$($afterAutostart.Count); exact key-name-value binding required." },
                [ordered]@{ name='No duplicate autostart'; passed=$afterAutostart.Count -le 1; details="before=$($beforeAutostart.Count); after=$($afterAutostart.Count)" },
                [ordered]@{ name='Start menu shortcut preserved'; passed=$startMenuPreserved; details="before=$($beforeStartMenu.Count); after=$($afterStartMenu.Count); target must be version B executable." }
            )
            if (@($state.checks | Where-Object { -not $_.passed }).Count) { throw 'One or more application updater assertions failed.' }
            $state.phase = 'application-update-completed'

            if ($UninstallAfterUpdate) {
                Write-Host 'Exit version B normally through the tray, then press Enter to run its registered uninstaller.'
                Read-Host | Out-Null
                if (@(Get-DeskPetRunningProcesses).Count) { throw 'Version B is still running; normal exit is required before uninstall.' }
                if ($PSCmdlet.ShouldProcess("$script:ProductName $currentVersion", 'Run the registered version B uninstaller and bounded cleanup checks')) {
                    $state.phase = 'uninstall-version-b'
                    & "$PSScriptRoot\uninstall-smoke-test.ps1" -ExpectedVersion $currentVersion -Confirm:$false
                    if ($LASTEXITCODE -ne 0) { throw 'Version B uninstall failed after the in-app update.' }
                    $state['versionBUninstalled'] = $true
                    $state.phase = 'completed'
                }
            }
            $state.phase = 'completed'
            $state.status = 'passed'
        }
    }
} catch {
    $failureType = $_.Exception.GetType().Name
    $safeFailureMessage = ConvertTo-PublicBetaSafeFailureMessage -Message $_.Exception.Message -RepositoryRoot $repo
    $caughtError = New-Object -TypeName System.Management.Automation.RuntimeException -ArgumentList $safeFailureMessage
    if ($null -eq $state) {
        $state = [ordered]@{
            schemaVersion=1; evidenceType='application_updater_e2e'; phase='initialization'; status='failed'
            whatIf=[bool]$WhatIfPreference; startedAtUtc=[DateTime]::UtcNow.ToString('o')
            currentInstallerExecutionAllowed=$false; endpointCandidateBinding=$false
            uiPendingTargetObserved=$false; uiConfirmedTargetObserved=$false
            uiPendingClearedAfterConfirmation=$false; uiOrderedTransitionObserved=$false
            installerExecutions=@(); checks=@(); recoveryCommands=@('.\scripts\windows\uninstall-smoke-test.ps1 -WhatIf')
        }
    }
    $state.status = 'failed'
    $state['failure'] = [ordered]@{
        phase=[string]$state.phase
        type=$failureType
        message=$safeFailureMessage
    }
} finally {
    if ($null -eq $state) {
        $state = [ordered]@{
            schemaVersion=1; evidenceType='application_updater_e2e'; phase='initialization'; status='failed'
            whatIf=[bool]$WhatIfPreference; startedAtUtc=[DateTime]::UtcNow.ToString('o')
            currentInstallerExecutionAllowed=$false; endpointCandidateBinding=$false
            uiPendingTargetObserved=$false; uiConfirmedTargetObserved=$false
            uiPendingClearedAfterConfirmation=$false; uiOrderedTransitionObserved=$false
            installerExecutions=@(); checks=@(); failure=[ordered]@{phase='initialization';type='RuntimeException';message='QA initialization failed.'}
            recoveryCommands=@('.\scripts\windows\uninstall-smoke-test.ps1 -WhatIf')
        }
        if ($null -eq $caughtError) { $caughtError = New-Object System.Management.Automation.RuntimeException 'QA initialization failed.' }
    }
    if ([string]::IsNullOrWhiteSpace($reportPath)) {
        try {
            [void][System.IO.Directory]::CreateDirectory($fallbackOutput)
            $reportPath = [System.IO.Path]::Combine($fallbackOutput, 'application-updater-result.json')
        } catch {
            if ($null -eq $caughtError) { $caughtError = New-Object System.Management.Automation.RuntimeException 'The fallback QA report directory could not be initialized.' }
        }
    }
    $state['finishedAtUtc'] = [DateTime]::UtcNow.ToString('o')
    try {
        $state['remainingInstallRecords'] = @(Get-DeskPetInstallRecords -IncludeLegacy).Count
        $state['remainingProcesses'] = @(Get-DeskPetRunningProcesses -IncludeLegacy).Count
        $state['finalProbeStatus'] = 'passed'
    } catch {
        $state.status = 'failed'
        $state['finalProbeStatus'] = 'failed'
        $finalProbeMessage = ConvertTo-PublicBetaSafeFailureMessage -Message $_.Exception.Message -RepositoryRoot $repo
        $state['finalProbeFailure'] = [ordered]@{ type=$_.Exception.GetType().Name; message=$finalProbeMessage }
        if ($null -eq $caughtError) { $caughtError = New-Object -TypeName System.Management.Automation.RuntimeException -ArgumentList $finalProbeMessage }
    }
    $savedWhatIfPreference = $WhatIfPreference
    $WhatIfPreference = $false
    try {
        if (-not [string]::IsNullOrWhiteSpace($reportPath)) {
            try {
                Write-PublicBetaAtomicJson -InputObject $state -LiteralPath $reportPath -Depth 16
            } catch {
                $state.status = 'failed'
                $reportWriteMessage = ConvertTo-PublicBetaSafeFailureMessage -Message $_.Exception.Message -RepositoryRoot $repo
                $state['reportWriteFailure'] = [ordered]@{ type=$_.Exception.GetType().Name; message=$reportWriteMessage }
                $fallbackReportPath = [System.IO.Path]::Combine($fallbackOutput, 'application-updater-result.json')
                try {
                    [void][System.IO.Directory]::CreateDirectory($fallbackOutput)
                    Write-PublicBetaAtomicJson -InputObject $state -LiteralPath $fallbackReportPath -Depth 16
                    $reportPath = $fallbackReportPath
                } catch {
                    $caughtError = New-Object System.Management.Automation.RuntimeException 'Both the requested and fallback QA reports could not be written.'
                    $reportPath = $null
                }
            }
        }
    } finally {
        $WhatIfPreference = $savedWhatIfPreference
    }
    if (-not [string]::IsNullOrWhiteSpace($reportPath)) { Write-Host "Application updater result: $reportPath" }
}

if ($null -ne $caughtError) { throw $caughtError }
if ($state.status -eq 'failed') { exit 2 }
exit 0
