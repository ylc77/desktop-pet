[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$windowsRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..'))
$repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($windowsRoot, '..', '..'))
. ([System.IO.Path]::Combine($windowsRoot, 'common.ps1'))
. ([System.IO.Path]::Combine($windowsRoot, 'public-beta-common.ps1'))

$results = @()
function Add-Test([string]$Name, [bool]$Passed, [string]$Details) {
    $script:results += [pscustomobject]@{ Name=$Name; Passed=$Passed; Details=$Details }
}
function Test-Equal([string]$Name, [object]$Expected, [object]$Actual) {
    Add-Test $Name ($Expected -eq $Actual) "expected=$Expected; actual=$Actual"
}
function Test-Throws([string]$Name, [scriptblock]$Action, [string]$Pattern) {
    try { & $Action; Add-Test $Name $false 'No exception was thrown.' }
    catch { Add-Test $Name ($_.Exception.Message -match $Pattern) $_.Exception.Message }
}
function Write-Utf8NoBom([string]$Path, [string]$Value) {
    [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding($false)))
}
function New-SettingsFixture([string]$CharacterId, [AllowNull()][string]$LastCheckAt) {
    [ordered]@{
        position=[ordered]@{x=12;y=34}; monitorName='QA'; scale=1.25; opacity=0.9
        characterId=$CharacterId; skinId='default'; alwaysOnTop=$true; autostart=$true
        animationsPaused=$false; volume=0.8; hideInFullscreen=$true; developerPanel=$false
        interactionsEnabled=$true; facing='right'; automaticUpdateChecks=$true
        updateLastCheckAt=$LastCheckAt; updateLastAvailableVersion=$null; updateSkippedVersion=$null
        updateLastFailureCategory=$null; pendingUpdateVersion=$null; lastConfirmedUpdateVersion=$null
    }
}
function New-PassingApplicationUpdaterChecks {
    @(
        'Version A updater artifact cryptographically verified',
        'Version B updater artifact cryptographically verified',
        'Remote endpoint candidate binding',
        'Version B installer was not invoked by QA',
        'Updater UI pending target observed',
        'Updater UI target confirmed after restart',
        'Updater UI ordered pending-to-confirmed transition',
        'Old version process exited',
        'New version process started',
        'New process uses version B executable',
        'Version B installation record',
        'Single uninstall record',
        'Settings preserved',
        'Character selection preserved',
        'Imported character package preserved and loadable',
        'Autostart state preserved',
        'No duplicate autostart',
        'Start menu shortcut preserved'
    ) | ForEach-Object { [ordered]@{name=$_;passed=$true} }
}

$root = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'desk-pet-application-updater-' + [guid]::NewGuid().ToString('N'))
try {
    [System.IO.Directory]::CreateDirectory($root) | Out-Null

    $directEnvironment = [pscustomobject]@{ evidenceType='direct_installer_overlay'; sourceReportStatus='passed'; status='passed' }
    $passedCheck = [pscustomobject]@{ status='passed' }
    $directValidation = Test-PublicBetaApplicationUpdaterEvidence -Environment $directEnvironment -Check $passedCheck
    Test-Equal 'Direct installer overlay is rejected as application updater evidence' $false ([bool]$directValidation.Valid)
    $applicationEnvironment = [pscustomobject]@{ evidenceType='application_updater_e2e'; sourceReportStatus='passed'; status='passed' }
    $applicationValidation = Test-PublicBetaApplicationUpdaterEvidence -Environment $applicationEnvironment -Check $passedCheck
    Test-Equal 'Synthetic summary without a raw report is rejected' $false ([bool]$applicationValidation.Valid)
    $failedSourceEnvironment = [pscustomobject]@{ evidenceType='application_updater_e2e'; sourceReportStatus='failed'; status='passed' }
    $failedSourceValidation = Test-PublicBetaApplicationUpdaterEvidence -Environment $failedSourceEnvironment -Check $passedCheck
    Test-Equal 'Failed source report cannot satisfy application updater evidence' $false ([bool]$failedSourceValidation.Valid)

    $evidenceDirectory = [System.IO.Path]::Combine($root, 'application-updater-evidence')
    $rawDirectory = [System.IO.Path]::Combine($evidenceDirectory, 'raw')
    [void][System.IO.Directory]::CreateDirectory($rawDirectory)
    $candidateHash = 'A' * 64
    $previousHash = 'B' * 64
    $rawEvidence = [ordered]@{
        schemaVersion=1; evidenceType='application_updater_e2e'; phase='completed'; status='passed'; whatIf=$false; failure=$null
        finalProbeStatus='passed'; currentVersion='0.2.1-beta.1'; previousInstallerSha256=$previousHash
        currentInstallerReferenceFile='candidate.exe'; publicKeyFingerprint=('D' * 64)
        currentInstallerExecutionAllowed=$false; currentInstallerSha256=$candidateHash
        installerExecutions=@([ordered]@{role='version_a';sha256=$previousHash})
        cryptographicallyVerifiedArtifactRoles=@('version_a','version_b')
        endpointCandidateBinding=$true; remoteLatestSha256=('C' * 64); remoteArtifactSignatureSha256=('E' * 64)
        remoteArtifactFile='candidate.exe'; remoteArtifactSizeBytes=4
        uiPendingTargetObserved=$true; uiConfirmedTargetObserved=$true; uiPendingClearedAfterConfirmation=$true; uiOrderedTransitionObserved=$true
        checks=@(New-PassingApplicationUpdaterChecks)
    }
    $rawEvidencePath = [System.IO.Path]::Combine($rawDirectory, 'application-updater-result.json')
    Write-PublicBetaAtomicJson -InputObject $rawEvidence -LiteralPath $rawEvidencePath
    $rawEvidenceHash = (Get-FileHash -LiteralPath $rawEvidencePath -Algorithm SHA256).Hash
    $boundEnvironment = [pscustomobject]@{
        schemaVersion=1; evidenceType='application_updater_e2e'; sourceReportStatus='passed'; status='passed'; expectedVersion='0.2.1-beta.1'
        sourceReportFile=[System.IO.Path]::Combine('raw','application-updater-result.json'); sourceReportSha256=$rawEvidenceHash
        artifact=[pscustomobject]@{installerSha256=$candidateHash;installerFile='candidate.exe';sizeBytes=4}
    }
    $boundValidation = Test-PublicBetaApplicationUpdaterEvidence -Environment $boundEnvironment -Check $passedCheck -EnvironmentDirectory $evidenceDirectory
    Test-Equal 'Raw-hash-bound application updater evidence is accepted' $true ([bool]$boundValidation.Valid)
    $boundEnvironment.sourceReportSha256 = '0' * 64
    $tamperedValidation = Test-PublicBetaApplicationUpdaterEvidence -Environment $boundEnvironment -Check $passedCheck -EnvironmentDirectory $evidenceDirectory
    Test-Equal 'Raw report hash mismatch is rejected' $false ([bool]$tamperedValidation.Valid)
    $boundEnvironment.sourceReportSha256 = $rawEvidenceHash
    $minimalRaw = [ordered]@{}
    foreach ($key in $rawEvidence.Keys) { $minimalRaw[$key] = $rawEvidence[$key] }
    $minimalRaw['checks'] = @(
        [ordered]@{name='Updater UI pending target observed';passed=$true},
        [ordered]@{name='Updater UI target confirmed after restart';passed=$true},
        [ordered]@{name='Remote endpoint candidate binding';passed=$true}
    )
    Write-PublicBetaAtomicJson -InputObject $minimalRaw -LiteralPath $rawEvidencePath
    $boundEnvironment.sourceReportSha256 = (Get-FileHash -LiteralPath $rawEvidencePath -Algorithm SHA256).Hash
    $minimalValidation = Test-PublicBetaApplicationUpdaterEvidence -Environment $boundEnvironment -Check $passedCheck -EnvironmentDirectory $evidenceDirectory
    Test-Equal 'Minimal synthetic raw report cannot satisfy preservation evidence' $false ([bool]$minimalValidation.Valid)
    $stringSchemaRaw = [ordered]@{}
    foreach ($key in $rawEvidence.Keys) { $stringSchemaRaw[$key] = $rawEvidence[$key] }
    $stringSchemaRaw['schemaVersion'] = '1'
    Write-PublicBetaAtomicJson -InputObject $stringSchemaRaw -LiteralPath $rawEvidencePath
    $boundEnvironment.sourceReportSha256 = (Get-FileHash -LiteralPath $rawEvidencePath -Algorithm SHA256).Hash
    $stringSchemaValidation = Test-PublicBetaApplicationUpdaterEvidence -Environment $boundEnvironment -Check $passedCheck -EnvironmentDirectory $evidenceDirectory
    Test-Equal 'String raw schemaVersion is rejected without crashing the Gate' $false ([bool]$stringSchemaValidation.Valid)

    $transitionStates = New-Object 'System.Collections.Generic.Queue[object]'
    $transitionStates.Enqueue([pscustomobject]@{ Versions=@('0.2.0-beta.1'); ProcessIds=@(101); RecordCount=1; PendingUpdateVersion=$null; LastConfirmedUpdateVersion=$null })
    $transitionStates.Enqueue([pscustomobject]@{ Versions=@('0.2.0-beta.1'); ProcessIds=@(101); RecordCount=1; PendingUpdateVersion='0.2.1-beta.1'; LastConfirmedUpdateVersion=$null })
    $transitionStates.Enqueue([pscustomobject]@{ Versions=@('0.2.1-beta.1'); ProcessIds=@(202); RecordCount=1; PendingUpdateVersion=$null; LastConfirmedUpdateVersion='0.2.1-beta.1' })
    $transitionStates.Enqueue([pscustomobject]@{ Versions=@('0.2.1-beta.1'); ProcessIds=@(202); RecordCount=1; PendingUpdateVersion=$null; LastConfirmedUpdateVersion='0.2.1-beta.1' })
    $elapsedValues = New-Object 'System.Collections.Generic.Queue[long]'
    $elapsedValues.Enqueue(0); $elapsedValues.Enqueue(1000); $elapsedValues.Enqueue(2000); $elapsedValues.Enqueue(3000)
    $transition = Wait-PublicBetaApplicationUpdaterTransition -PreviousVersion '0.2.0-beta.1' -CurrentVersion '0.2.1-beta.1' `
        -InitialProcessIds @(101) -TimeoutSeconds 30 -Probe { $transitionStates.Dequeue() } -Delay { param($Milliseconds) } `
        -GetElapsedMilliseconds { $elapsedValues.Dequeue() }
    Test-Equal 'Delayed in-app transition completes' $true ([bool]$transition.Complete)
    Test-Equal 'Old process exit is observed' $true ([bool]$transition.OldProcessesExited)
    Test-Equal 'New process id is observed' 202 ([int]$transition.NewProcessIds[0])
    Test-Equal 'Updater pending target is observed' $true ([bool]$transition.PendingTargetObserved)
    Test-Equal 'Updater restart confirmation is observed' $true ([bool]$transition.ConfirmedTargetObserved)
    Test-Equal 'Pending, restart, and confirmation were observed in order' $true ([bool]$transition.OrderedTransitionObserved)

    $reverseStates = New-Object 'System.Collections.Generic.Queue[object]'
    $reverseStates.Enqueue([pscustomobject]@{ Versions=@('0.2.0-beta.1'); ProcessIds=@(101); RecordCount=1; PendingUpdateVersion=$null; LastConfirmedUpdateVersion=$null })
    $reverseStates.Enqueue([pscustomobject]@{ Versions=@('0.2.1-beta.1'); ProcessIds=@(202); RecordCount=1; PendingUpdateVersion=$null; LastConfirmedUpdateVersion='0.2.1-beta.1' })
    $reverseStates.Enqueue([pscustomobject]@{ Versions=@('0.2.1-beta.1'); ProcessIds=@(202); RecordCount=1; PendingUpdateVersion='0.2.1-beta.1'; LastConfirmedUpdateVersion='0.2.1-beta.1' })
    $reverseElapsed = New-Object 'System.Collections.Generic.Queue[long]'
    $reverseElapsed.Enqueue(0); $reverseElapsed.Enqueue(1000); $reverseElapsed.Enqueue(30000)
    $reverseTransition = Wait-PublicBetaApplicationUpdaterTransition -PreviousVersion '0.2.0-beta.1' -CurrentVersion '0.2.1-beta.1' `
        -InitialProcessIds @(101) -TimeoutSeconds 30 -Probe { $reverseStates.Dequeue() } -Delay { param($Milliseconds) } `
        -GetElapsedMilliseconds { $reverseElapsed.Dequeue() }
    Test-Equal 'Confirmed-before-pending sequence cannot complete' $false ([bool]$reverseTransition.Complete)
    Test-Equal 'Version B-only pending state is not attributed to version A' $false ([bool]$reverseTransition.PendingTargetObserved)

    $timeoutState = [pscustomobject]@{ Versions=@('0.2.0-beta.1'); ProcessIds=@(303); RecordCount=1; PendingUpdateVersion=$null; LastConfirmedUpdateVersion=$null }
    $timeoutTransition = Wait-PublicBetaApplicationUpdaterTransition -PreviousVersion '0.2.0-beta.1' -CurrentVersion '0.2.1-beta.1' `
        -InitialProcessIds @(303) -TimeoutSeconds 30 -Probe { $timeoutState } -Delay { param($Milliseconds) } `
        -GetElapsedMilliseconds { 30000 }
    Test-Equal 'Transition timeout is reported' $true ([bool]$timeoutTransition.TimedOut)
    Test-Equal 'Timeout is not a completed update' $false ([bool]$timeoutTransition.Complete)

    $settingsBeforePath = [System.IO.Path]::Combine($root, 'settings-before.json')
    $settingsAfterPath = [System.IO.Path]::Combine($root, 'settings-after.json')
    Write-Utf8NoBom $settingsBeforePath ((New-SettingsFixture -CharacterId 'qa-character' -LastCheckAt $null) | ConvertTo-Json -Depth 6)
    Write-Utf8NoBom $settingsAfterPath ((New-SettingsFixture -CharacterId 'qa-character' -LastCheckAt '2026-01-01T00:00:00Z') | ConvertTo-Json -Depth 6)
    $beforeSnapshot = Get-DeskPetPreservedSettingsSnapshot -Path $settingsBeforePath
    $afterSnapshot = Get-DeskPetPreservedSettingsSnapshot -Path $settingsAfterPath
    Test-Equal 'Updater bookkeeping changes do not fail stable settings preservation' $beforeSnapshot.Fingerprint $afterSnapshot.Fingerprint

    $wrappedSettingsPath = [System.IO.Path]::Combine($root, 'settings-wrapped.json')
    Write-Utf8NoBom $wrappedSettingsPath ([ordered]@{
        settings=(New-SettingsFixture -CharacterId 'qa-character' -LastCheckAt $null)
    } | ConvertTo-Json -Depth 7)
    $wrappedSnapshot = Get-DeskPetPreservedSettingsSnapshot -Path $wrappedSettingsPath
    Test-Equal 'Native wrapped settings format preserves the same stable values' $beforeSnapshot.Fingerprint $wrappedSnapshot.Fingerprint

    $invalidWrappedSettingsPath = [System.IO.Path]::Combine($root, 'settings-wrapped-invalid.json')
    Write-Utf8NoBom $invalidWrappedSettingsPath ([ordered]@{ settings=[ordered]@{ scale=1.25 } } | ConvertTo-Json -Depth 4)
    Test-Throws 'Wrapped settings still require every preserved property' {
        Get-DeskPetPreservedSettingsSnapshot -Path $invalidWrappedSettingsPath | Out-Null
    } 'missing the preserved property: position'

    Write-Utf8NoBom $settingsAfterPath ((New-SettingsFixture -CharacterId 'different-character' -LastCheckAt '2026-01-01T00:00:00Z') | ConvertTo-Json -Depth 6)
    $changedSnapshot = Get-DeskPetPreservedSettingsSnapshot -Path $settingsAfterPath
    Add-Test 'Character selection change is detected' ($beforeSnapshot.Fingerprint -ne $changedSnapshot.Fingerprint) 'Stable fingerprint must change.'

    $expectedExecutable = 'C:\Program Files\七酱桌宠\desktop_pet.exe'
    $autostartEntries = @([pscustomobject]@{Key='HKCU:\Run';Name='七酱桌宠';Value=('"' + $expectedExecutable + '" --autostart')})
    $autostartBefore = Get-PublicBetaAutostartSnapshot -Entries $autostartEntries -ExpectedExecutablePath $expectedExecutable
    $autostartAfter = Get-PublicBetaAutostartSnapshot -Entries $autostartEntries -ExpectedExecutablePath $expectedExecutable
    Test-Equal 'Exact autostart key-name-value snapshot is stable' $autostartBefore.Fingerprint $autostartAfter.Fingerprint
    Test-Equal 'Autostart command targets desktop_pet.exe exactly' $true ([bool]$autostartAfter.AllTargetExpectedExecutable)
    $wrongAutostart = Get-PublicBetaAutostartSnapshot -Entries @([pscustomobject]@{Key='HKCU:\Run';Name='七酱桌宠';Value='"C:\stale\desktop_pet.exe"'}) -ExpectedExecutablePath $expectedExecutable
    Test-Equal 'Stale autostart executable is rejected' $false ([bool]$wrongAutostart.AllTargetExpectedExecutable)
    $shortcutEntry = [pscustomobject]@{FullName='C:\Start Menu\七酱桌宠.lnk'}
    $shortcutSnapshot = Get-PublicBetaStartMenuSnapshot -Entries @($shortcutEntry) -ExpectedExecutablePath $expectedExecutable `
        -ShortcutTargetResolver { param($ShortcutPath) $expectedExecutable }
    Test-Equal 'Start menu target is validated against desktop_pet.exe' $true ([bool]$shortcutSnapshot.AllTargetExpectedExecutable)

    $safeRepositoryFailure = ConvertTo-PublicBetaSafeFailureMessage `
        -Message "Missing file: $repo\private\artifact.exe" -RepositoryRoot $repo
    Add-Test 'Repository paths are tokenized in failure messages' `
        ($safeRepositoryFailure.Contains('%REPOSITORY%') -and -not $safeRepositoryFailure.Contains($repo)) $safeRepositoryFailure
    $safeUnknownFailure = ConvertTo-PublicBetaSafeFailureMessage `
        -Message 'Missing file: Z:\private\artifact.exe' -RepositoryRoot $repo
    Add-Test 'Unknown absolute paths are reduced to a role marker' `
        ($safeUnknownFailure.Contains('<absolute-path>') -and -not $safeUnknownFailure.Contains('Z:\private')) $safeUnknownFailure
    $safeForwardSlashFailure = ConvertTo-PublicBetaSafeFailureMessage `
        -Message 'Missing file: C:/Users/private-user/artifact.exe' -RepositoryRoot $repo
    Add-Test 'Forward-slash drive paths are redacted' `
        ($safeForwardSlashFailure.Contains('<absolute-path>') -and -not $safeForwardSlashFailure.Contains('private-user')) $safeForwardSlashFailure
    $safeFileUriFailure = ConvertTo-PublicBetaSafeFailureMessage `
        -Message 'Missing file: file:///C:/Users/private-user/artifact.exe' -RepositoryRoot $repo
    Add-Test 'File URI paths are redacted' `
        ($safeFileUriFailure.Contains('<absolute-file-uri>') -and -not $safeFileUriFailure.Contains('private-user')) $safeFileUriFailure
    $safeUncFailure = ConvertTo-PublicBetaSafeFailureMessage `
        -Message 'Missing file: //private-server/private-share/artifact.exe' -RepositoryRoot $repo
    Add-Test 'Forward-slash UNC paths are redacted' `
        ($safeUncFailure.Contains('<absolute-unc-path>') -and -not $safeUncFailure.Contains('private-server')) $safeUncFailure

    $applicationScriptPath = [System.IO.Path]::Combine($windowsRoot, 'application-updater-smoke-test.ps1')
    $applicationScriptText = [System.IO.File]::ReadAllText($applicationScriptPath, [System.Text.Encoding]::UTF8)
    $upgradeScriptText = [System.IO.File]::ReadAllText(([System.IO.Path]::Combine($windowsRoot, 'upgrade-smoke-test.ps1')), [System.Text.Encoding]::UTF8)
    $dispatcherText = [System.IO.File]::ReadAllText(([System.IO.Path]::Combine($windowsRoot, 'run-public-beta-qa.ps1')), [System.Text.Encoding]::UTF8)
    $publicBetaCommonText = [System.IO.File]::ReadAllText(([System.IO.Path]::Combine($windowsRoot, 'public-beta-common.ps1')), [System.Text.Encoding]::UTF8)
    Add-Test 'Application updater script invokes only the version A installer helper' `
        ($applicationScriptText.Contains('Invoke-VersionAInstaller -Path $previousInstaller') -and -not $applicationScriptText.Contains('Invoke-VersionAInstaller -Path $currentInstallerReference')) `
        'Version B installer is reference-only.'
    Add-Test 'Application updater state explicitly prohibits version B installer execution' `
        $applicationScriptText.Contains('currentInstallerExecutionAllowed=$false') 'Guard is present in the report schema.'
    Add-Test 'Explicit updater metadata does not inherit an unrelated historical root release manifest' `
        ($applicationScriptText.Contains('$versionReleaseDirectory = if ([string]::IsNullOrWhiteSpace($UpdaterManifestPath))') -and
            $applicationScriptText.Contains('-ReleaseDirectory $versionReleaseDirectory')) `
        'The explicitly supplied updater manifest owns candidate release metadata validation.'
    Add-Test 'Direct overlay script declares its distinct evidence type' `
        $upgradeScriptText.Contains("evidenceType='direct_installer_overlay'") 'Direct overlay cannot masquerade as the application updater.'
    Add-Test 'Dispatcher exposes an independent ApplicationUpdater mode' `
        ($dispatcherText.Contains("'ApplicationUpdater'") -and $dispatcherText.Contains('application-updater-smoke-test.ps1')) 'Independent mode and script dispatch are present.'
    Add-Test 'ApplicationUpdater dispatcher uses the explicit updater manifest as release metadata' `
        ($dispatcherText.Contains("if (`$Mode -eq 'ApplicationUpdater' -and -not [string]::IsNullOrWhiteSpace(`$UpdaterManifestPath))") -and
            $dispatcherText.Contains('-ReleaseDirectory $versionReleaseDirectory')) `
        'Historical root release metadata must not contaminate an explicitly bound updater candidate.'
    $safeEnumerationIndex = $publicBetaCommonText.IndexOf('$packageFiles = @(Get-PublicBetaSafeCharacterPackageFiles')
    $manifestReadIndex = $publicBetaCommonText.IndexOf('$manifest = Get-Content -LiteralPath $manifestPath')
    Add-Test 'Character package reparse rejection is ordered before manifest and asset reads' `
        ($safeEnumerationIndex -ge 0 -and $manifestReadIndex -gt $safeEnumerationIndex -and
            -not $publicBetaCommonText.Contains('Get-ChildItem -LiteralPath $characterDirectory -Force -Recurse')) `
        "safeEnumerationIndex=$safeEnumerationIndex; manifestReadIndex=$manifestReadIndex"

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($applicationScriptPath, [ref]$tokens, [ref]$parseErrors)
    Test-Equal 'Application updater script parses without errors' 0 @($parseErrors).Count
    $startProcessCommands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-Process' }, $true))
    $currentInstallerStarts = @($startProcessCommands | Where-Object { $_.Extent.Text -match '\$currentInstallerReference|\$InstallerPath' })
    Test-Equal 'No Start-Process command references the version B installer' 0 $currentInstallerStarts.Count

    $previousVersion = '0.0.9'
    $currentVersion = [string]$script:TauriConfig.version
    $previousInstaller = [System.IO.Path]::Combine($root, "$script:ProductName`_$previousVersion`_x64-setup.exe")
    $currentInstaller = [System.IO.Path]::Combine($root, "$script:ProductName`_$currentVersion`_x64-setup.exe")
    [System.IO.File]::WriteAllBytes($previousInstaller, [byte[]](1,2,3,4))
    [System.IO.File]::WriteAllBytes($currentInstaller, [byte[]](5,6,7,8))
    $fingerprint = 'A' * 64
    $previousManifestPath = [System.IO.Path]::Combine($root, 'previous-updater-release-manifest.json')
    $currentManifestPath = [System.IO.Path]::Combine($root, 'current-updater-release-manifest.json')
    $previousManifest = [ordered]@{
        schemaVersion=1
        version=$previousVersion; identifier=$script:AppIdentifier; publicKeyFingerprint=$fingerprint
        artifactSha256=(Get-FileHash -LiteralPath $previousInstaller -Algorithm SHA256).Hash; dirtyWorktree=$false
        endpoint='https://updates.example.invalid/latest.json'; artifactFile=[System.IO.Path]::GetFileName($previousInstaller); signatureFile=([System.IO.Path]::GetFileName($previousInstaller) + '.sig')
    }
    $currentManifest = [ordered]@{
        schemaVersion=1
        version=$currentVersion; identifier=$script:AppIdentifier; publicKeyFingerprint=$fingerprint
        artifactSha256=(Get-FileHash -LiteralPath $currentInstaller -Algorithm SHA256).Hash; dirtyWorktree=$false
        endpoint='https://updates.example.invalid/latest.json'; artifactFile=[System.IO.Path]::GetFileName($currentInstaller); signatureFile=([System.IO.Path]::GetFileName($currentInstaller) + '.sig')
    }
    Write-Utf8NoBom $previousManifestPath ($previousManifest | ConvertTo-Json -Depth 5)
    Write-Utf8NoBom $currentManifestPath ($currentManifest | ConvertTo-Json -Depth 5)
    Write-Utf8NoBom ($previousInstaller + '.sig') 'fixture-signature-a'
    Write-Utf8NoBom ($currentInstaller + '.sig') 'fixture-signature-b'
    $previousArtifactSet = Resolve-PublicBetaUpdaterArtifactSet -Role 'version_a' -Manifest ([pscustomobject]$previousManifest) `
        -ManifestPath $previousManifestPath -ExpectedInstallerSha256 ([string]$previousManifest.artifactSha256)
    $currentArtifactSet = Resolve-PublicBetaUpdaterArtifactSet -Role 'version_b' -Manifest ([pscustomobject]$currentManifest) `
        -ManifestPath $currentManifestPath -ExpectedInstallerSha256 ([string]$currentManifest.artifactSha256)
    $verifiedArtifacts = New-Object 'System.Collections.Generic.List[string]'
    $mockVerifier = {
        param($ArtifactPath, $SignaturePath, $PublicKeyPath)
        $verifiedArtifacts.Add([System.IO.Path]::GetFileName($ArtifactPath)) | Out-Null
        return [System.IO.File]::Exists($SignaturePath) -and $PublicKeyPath -eq 'fixture-public-key'
    }.GetNewClosure()
    Assert-PublicBetaUpdaterArtifactSignatures -ArtifactSets @($previousArtifactSet, $currentArtifactSet) `
        -PublicKeyPath 'fixture-public-key' -SignatureVerifier $mockVerifier
    Test-Equal 'Signature verifier is called for both version A and version B' 2 $verifiedArtifacts.Count
    Add-Test 'A and B artifact filenames were both verified' `
        ($verifiedArtifacts.Contains([System.IO.Path]::GetFileName($previousInstaller)) -and $verifiedArtifacts.Contains([System.IO.Path]::GetFileName($currentInstaller))) `
        ($verifiedArtifacts -join ',')
    Test-Throws 'A or B signature verification failure is fail closed' {
        Assert-PublicBetaUpdaterArtifactSignatures -ArtifactSets @($previousArtifactSet, $currentArtifactSet) `
            -PublicKeyPath 'fixture-public-key' -SignatureVerifier { param($ArtifactPath,$SignaturePath,$PublicKeyPath) return $false }
    } 'signature verification failed'

    $downloadUrl = "https://downloads.example.invalid/$([Uri]::EscapeDataString([System.IO.Path]::GetFileName($currentInstaller)))"
    $latestDocument = [ordered]@{
        version=$currentVersion
        platforms=[ordered]@{
            'windows-x86_64'=[ordered]@{
                url=$downloadUrl; size=(Get-Item -LiteralPath $currentInstaller).Length; signature='fixture-signature-b'
            }
        }
    }
    $latestJson = $latestDocument | ConvertTo-Json -Depth 6
    $fixtureDownloader = {
        param($Uri,$Destination)
        [System.IO.File]::WriteAllText($Destination, $latestJson, (New-Object System.Text.UTF8Encoding($false)))
        [pscustomobject]@{FinalUri=$Uri}
    }.GetNewClosure()
    $fixtureLatestValidator = {
        param($LatestPath,$FromVersion,$ToVersion,$TargetPlatform,$CandidateArtifact,$CandidateSignature,$ProductionPublicKey)
        [pscustomobject]@{CryptographicSignatureVerified=$true}
    }
    $remoteBinding = Invoke-PublicBetaRemoteLatestBinding -Endpoint 'https://updates.example.invalid/latest.json' `
        -CurrentVersion $previousVersion -ExpectedVersion $currentVersion -Platform 'windows-x86_64' -ExpectedDownloadUrl $downloadUrl `
        -ArtifactPath $currentInstaller -SignaturePath ($currentInstaller + '.sig') -PublicKeyPath 'fixture-public-key' `
        -RepositoryRoot $repo -Downloader $fixtureDownloader -LatestValidator $fixtureLatestValidator
    Test-Equal 'Remote latest.json is bound to the local version B candidate' $true ([bool]$remoteBinding.Bound)
    Test-Equal 'Remote candidate binding records a metadata hash' 64 ([string]$remoteBinding.LatestSha256).Length
    Test-Throws 'Remote latest.json URL mismatch is rejected' {
        Invoke-PublicBetaRemoteLatestBinding -Endpoint 'https://updates.example.invalid/latest.json' `
            -CurrentVersion $previousVersion -ExpectedVersion $currentVersion -Platform 'windows-x86_64' -ExpectedDownloadUrl 'https://downloads.example.invalid/wrong.exe' `
            -ArtifactPath $currentInstaller -SignaturePath ($currentInstaller + '.sig') -PublicKeyPath 'fixture-public-key' `
            -RepositoryRoot $repo -Downloader $fixtureDownloader -LatestValidator $fixtureLatestValidator
    } 'download URL does not match'
    $unsafeManifest = [pscustomobject]@{
        artifactFile='..\outside.exe'; signatureFile='..\outside.exe.sig'; artifactSha256=[string]$previousManifest.artifactSha256
    }
    Test-Throws 'Manifest artifact filename traversal is rejected' {
        Resolve-PublicBetaUpdaterArtifactSet -Role 'version_a' -Manifest $unsafeManifest `
            -ManifestPath $previousManifestPath -ExpectedInstallerSha256 ([string]$previousManifest.artifactSha256)
    } 'unsafe artifact filename'
    $previewOutput = [System.IO.Path]::Combine($root, '中文 preview output')
    $global:LASTEXITCODE = 0
    & $applicationScriptPath -PreviousInstallerPath $previousInstaller -InstallerPath $currentInstaller `
        -PreviousUpdaterManifestPath $previousManifestPath -UpdaterManifestPath $currentManifestPath `
        -ExpectedVersion $currentVersion -OutputDirectory $previewOutput -WhatIf
    $previewExitCode = $LASTEXITCODE
    $previewReportPath = [System.IO.Path]::Combine($previewOutput, 'application-updater-result.json')
    $previewReport = Get-Content -LiteralPath $previewReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Equal 'WhatIf preview succeeds without starting a fake installer' 0 $previewExitCode
    Test-Equal 'WhatIf report remains not executed' 'not_executed' ([string]$previewReport.status)
    Test-Equal 'WhatIf records no installer execution' 0 @($previewReport.installerExecutions).Count
    Test-Equal 'WhatIf handles a Unicode and space-containing output path' $true ([System.IO.File]::Exists($previewReportPath))

    $failureOutput = [System.IO.Path]::Combine($root, 'failure-report')
    $failureWasRaised = $false
    try {
        & $applicationScriptPath -PreviousInstallerPath $previousInstaller -InstallerPath $currentInstaller `
            -PreviousUpdaterManifestPath $previousManifestPath -UpdaterManifestPath $currentManifestPath `
            -ExpectedVersion $currentVersion -OutputDirectory $failureOutput -Confirm:$false
    } catch {
        $failureWasRaised = $true
    }
    $failureReportPath = [System.IO.Path]::Combine($failureOutput, 'application-updater-result.json')
    $failureReport = Get-Content -LiteralPath $failureReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Equal 'Unsafe real run is rejected before any installer starts' $true $failureWasRaised
    Test-Equal 'Rejected real run still writes a failed report' 'failed' ([string]$failureReport.status)
    Test-Equal 'Rejected real run records no installer execution' 0 @($failureReport.installerExecutions).Count

    $dispatcherFailureOutput = [System.IO.Path]::Combine($root, 'dispatcher-failure')
    $global:LASTEXITCODE = 0
    & ([System.IO.Path]::Combine($windowsRoot, 'run-public-beta-qa.ps1')) -Mode ApplicationUpdater `
        -PreviousInstallerPath $previousInstaller -InstallerPath $currentInstaller `
        -PreviousUpdaterManifestPath $previousManifestPath -UpdaterManifestPath $currentManifestPath `
        -ExpectedVersion $currentVersion -OutputDirectory $dispatcherFailureOutput -Confirm:$false
    $dispatcherExitCode = $LASTEXITCODE
    $dispatcherRawPath = [System.IO.Path]::Combine($dispatcherFailureOutput, 'application-updater', 'raw', 'application-updater-result.json')
    $dispatcherSummaryPath = [System.IO.Path]::Combine($dispatcherFailureOutput, 'application-updater', 'environment-result.json')
    $dispatcherSummaryText = [System.IO.File]::ReadAllText($dispatcherSummaryPath, [System.Text.Encoding]::UTF8)
    $dispatcherSummary = $dispatcherSummaryText | ConvertFrom-Json
    Test-Equal 'Dispatcher failure returns a nonzero exit code' 2 $dispatcherExitCode
    Test-Equal 'Dispatcher failure preserves the raw report' $true ([System.IO.File]::Exists($dispatcherRawPath))
    Test-Equal 'Dispatcher failure writes a summary report' 'failed' ([string]$dispatcherSummary.status)
    Add-Test 'Dispatcher summary binds the raw report hash' `
        ([string]$dispatcherSummary.sourceReportSha256 -eq (Get-FileHash -LiteralPath $dispatcherRawPath -Algorithm SHA256).Hash) `
        ([string]$dispatcherSummary.sourceReportSha256)
    Add-Test 'Dispatcher failure notes contain no local absolute fixture path' `
        (-not $dispatcherSummaryText.Contains($root)) 'Summary notes must contain only redacted failure text.'

    $missingInstaller = [System.IO.Path]::Combine($root, 'private', 'missing-version-a.exe')
    $missingFileOutput = [System.IO.Path]::Combine($root, 'missing-file-report')
    $missingFileRaised = $false
    try {
        & $applicationScriptPath -PreviousInstallerPath $missingInstaller -InstallerPath $currentInstaller `
            -PreviousUpdaterManifestPath $previousManifestPath -UpdaterManifestPath $currentManifestPath `
            -ExpectedVersion $currentVersion -OutputDirectory $missingFileOutput -WhatIf
    } catch {
        $missingFileRaised = $true
    }
    $missingFileReportPath = [System.IO.Path]::Combine($missingFileOutput, 'application-updater-result.json')
    $missingFileReportText = [System.IO.File]::ReadAllText($missingFileReportPath, [System.Text.Encoding]::UTF8)
    $missingFileReport = $missingFileReportText | ConvertFrom-Json
    Test-Equal 'Missing installer failure still writes a report' $true $missingFileRaised
    Test-Equal 'Failure report preserves the failure phase' 'validation' ([string]$missingFileReport.failure.phase)
    Test-Equal 'Failure report preserves the exception type' 'RuntimeException' ([string]$missingFileReport.failure.type)
    Add-Test 'Missing-file report contains no local absolute test path' `
        (-not $missingFileReportText.Contains($root) -and -not ([string]$missingFileReport.failure.message).Contains($root)) `
        ([string]$missingFileReport.failure.message)

    $earlyPathOutput = [System.IO.Path]::Combine($root, 'early-path-report')
    $earlyPathRaised = $false
    try {
        & $applicationScriptPath -PreviousInstallerPath $previousInstaller -InstallerPath $currentInstaller `
            -PreviousUpdaterManifestPath 'bad|manifest-path' -UpdaterManifestPath $currentManifestPath `
            -ExpectedVersion $currentVersion -OutputDirectory $earlyPathOutput -WhatIf
    } catch { $earlyPathRaised = $true }
    $earlyPathReportPath = [System.IO.Path]::Combine($earlyPathOutput, 'application-updater-result.json')
    $earlyPathReport = Get-Content -LiteralPath $earlyPathReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Equal 'Early user-path resolution failure is reported' $true $earlyPathRaised
    Test-Equal 'Early user-path resolution failure writes a failed report' 'failed' ([string]$earlyPathReport.status)
    Test-Equal 'Early user-path report records the path-validation phase' 'path-validation' ([string]$earlyPathReport.failure.phase)

    $stringSchemaManifestPath = [System.IO.Path]::Combine($root, 'string-schema-updater-manifest.json')
    $stringSchemaManifest = [ordered]@{}
    foreach ($key in $previousManifest.Keys) { $stringSchemaManifest[$key] = $previousManifest[$key] }
    $stringSchemaManifest['schemaVersion'] = '1'
    Write-Utf8NoBom $stringSchemaManifestPath ($stringSchemaManifest | ConvertTo-Json -Depth 5)
    $stringSchemaOutput = [System.IO.Path]::Combine($root, 'string-schema-report')
    $stringSchemaRaised = $false
    try {
        & $applicationScriptPath -PreviousInstallerPath $previousInstaller -InstallerPath $currentInstaller `
            -PreviousUpdaterManifestPath $stringSchemaManifestPath -UpdaterManifestPath $currentManifestPath `
            -ExpectedVersion $currentVersion -OutputDirectory $stringSchemaOutput -WhatIf
    } catch { $stringSchemaRaised = $true }
    $stringSchemaReport = Get-Content -LiteralPath ([System.IO.Path]::Combine($stringSchemaOutput, 'application-updater-result.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Equal 'String updater manifest schemaVersion is rejected' $true $stringSchemaRaised
    Test-Equal 'Invalid manifest schema fails closed with a report' 'failed' ([string]$stringSchemaReport.status)

    $stringDirtyManifestPath = [System.IO.Path]::Combine($root, 'string-dirty-updater-manifest.json')
    $stringDirtyManifest = [ordered]@{}
    foreach ($key in $previousManifest.Keys) { $stringDirtyManifest[$key] = $previousManifest[$key] }
    $stringDirtyManifest['dirtyWorktree'] = 'false'
    Write-Utf8NoBom $stringDirtyManifestPath ($stringDirtyManifest | ConvertTo-Json -Depth 5)
    $stringDirtyOutput = [System.IO.Path]::Combine($root, 'string-dirty-report')
    $stringDirtyRaised = $false
    try {
        & $applicationScriptPath -PreviousInstallerPath $previousInstaller -InstallerPath $currentInstaller `
            -PreviousUpdaterManifestPath $stringDirtyManifestPath -UpdaterManifestPath $currentManifestPath `
            -ExpectedVersion $currentVersion -OutputDirectory $stringDirtyOutput -WhatIf
    } catch { $stringDirtyRaised = $true }
    $stringDirtyReport = Get-Content -LiteralPath ([System.IO.Path]::Combine($stringDirtyOutput, 'application-updater-result.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Equal 'String false dirtyWorktree cannot pass the clean artifact gate' $true $stringDirtyRaised
    Test-Equal 'Invalid dirtyWorktree type fails closed with a report' 'failed' ([string]$stringDirtyReport.status)
} finally {
    if ([System.IO.Directory]::Exists($root)) { [System.IO.Directory]::Delete($root, $true) }
}

$results | Format-Table -AutoSize
$hostIsPowerShell51 = $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
[pscustomobject]@{ Name='Windows PowerShell 5.1 host'; Passed=$hostIsPowerShell51; Details=$PSVersionTable.PSVersion.ToString() } | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -or -not $hostIsPowerShell51) { exit 1 }
