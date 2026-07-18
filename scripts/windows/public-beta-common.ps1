Set-StrictMode -Version Latest

function Get-PublicBetaHostFacts {
    $savedWhatIfVariable = Get-Variable -Name WhatIfPreference -Scope Script -ErrorAction SilentlyContinue
    $savedWhatIfPreference = if ($null -eq $savedWhatIfVariable) { $false } else { [bool]$savedWhatIfVariable.Value }
    $script:WhatIfPreference = $false
    try {
        try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { $os = $null }
        try { $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch { $computer = $null }
    } finally {
        if ($null -eq $savedWhatIfVariable) { Remove-Variable -Name WhatIfPreference -Scope Script -ErrorAction SilentlyContinue }
        else { $script:WhatIfPreference = $savedWhatIfPreference }
    }
    $manufacturer = [string](Get-ObjectPropertyValue $computer 'Manufacturer')
    $model = [string](Get-ObjectPropertyValue $computer 'Model')
    [ordered]@{
        windowsCaption=$(if($os){[string]$os.Caption}else{[Environment]::OSVersion.VersionString})
        windowsVersion=$(if($os){[string]$os.Version}else{[Environment]::OSVersion.Version.ToString()})
        windowsBuild=$(if($os){[string]$os.BuildNumber}else{[Environment]::OSVersion.Version.Build.ToString()})
        architecture=Get-NativeProcessorArchitecture
        isVirtualMachine=($manufacturer -match 'Microsoft Corporation|VMware|innotek|QEMU|Xen|Parallels' -or $model -match 'Virtual|VMware|VirtualBox|KVM')
        virtualMachineVendor=$(if ($manufacturer -or $model) { "$manufacturer $model".Trim() } else { $null })
    }
}

function Get-PublicBetaArtifactFacts {
    param([AllowNull()][string]$InstallerPath)
    if ([string]::IsNullOrWhiteSpace($InstallerPath) -or -not [System.IO.File]::Exists($InstallerPath)) {
        return [ordered]@{ installerFile=$null; installerSha256=$null; signatureStatus=$null; sizeBytes=$null }
    }
    $savedWhatIfVariable = Get-Variable -Name WhatIfPreference -Scope Script -ErrorAction SilentlyContinue
    $savedWhatIfPreference = if ($null -eq $savedWhatIfVariable) { $false } else { [bool]$savedWhatIfVariable.Value }
    $script:WhatIfPreference = $false
    try {
        $item = Get-Item -LiteralPath $InstallerPath
        $hash = Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256
        $signature = Get-AuthenticodeSignature -FilePath $item.FullName
    } finally {
        if ($null -eq $savedWhatIfVariable) { Remove-Variable -Name WhatIfPreference -Scope Script -ErrorAction SilentlyContinue }
        else { $script:WhatIfPreference = $savedWhatIfPreference }
    }
    [ordered]@{
        installerFile=$item.Name
        installerSha256=$hash.Hash
        signatureStatus=[string]$signature.Status
        sizeBytes=$item.Length
    }
}

function New-PublicBetaEnvironmentResult {
    param(
        [Parameter(Mandatory)][string]$EnvironmentId,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][ValidateSet('passed','failed','blocked','not_executed')][string]$Status,
        [Parameter(Mandatory)][string]$GitCommit,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][object]$HostFacts,
        [Parameter(Mandatory)][object]$ArtifactFacts,
        [AllowEmptyCollection()][object[]]$Checks = @(),
        [AllowEmptyCollection()][string[]]$Notes = @()
    )
    [ordered]@{
        schemaVersion=1
        environmentId=$EnvironmentId
        mode=$Mode
        status=$Status
        testEnvironment=$EnvironmentId
        windows=$HostFacts
        testedAtUtc=[DateTime]::UtcNow.ToString('o')
        gitCommit=$GitCommit
        artifact=$ArtifactFacts
        command=$Command
        checks=@($Checks)
        notes=@($Notes)
    }
}

function Write-PublicBetaEnvironmentResult {
    param(
        [Parameter(Mandatory)][object]$Result,
        [Parameter(Mandatory)][string]$Directory
    )
    [System.IO.Directory]::CreateDirectory($Directory) | Out-Null
    $path = [System.IO.Path]::Combine($Directory, 'environment-result.json')
    Write-PublicBetaAtomicJson -InputObject $Result -LiteralPath $path -Depth 14
    return $path
}

function Write-PublicBetaAtomicJson {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$LiteralPath,
        [ValidateRange(2, 32)][int]$Depth = 14
    )
    $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($LiteralPath))
    [void][System.IO.Directory]::CreateDirectory($directory)
    $temporaryPath = [System.IO.Path]::Combine($directory, ([System.IO.Path]::GetFileName($LiteralPath) + '.tmp-' + [Guid]::NewGuid().ToString('N')))
    $backupPath = [System.IO.Path]::Combine($directory, ([System.IO.Path]::GetFileName($LiteralPath) + '.bak-' + [Guid]::NewGuid().ToString('N')))
    $encoding = New-Object System.Text.UTF8Encoding($false)
    try {
        $json = $InputObject | ConvertTo-Json -Depth $Depth
        [System.IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, $encoding)
        if ([System.IO.File]::Exists($LiteralPath)) {
            [System.IO.File]::Replace($temporaryPath, $LiteralPath, $backupPath, $true)
            [System.IO.File]::Delete($backupPath)
        } else {
            [System.IO.File]::Move($temporaryPath, $LiteralPath)
        }
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            try { [System.IO.File]::Delete($temporaryPath) } catch { }
        }
        if ([System.IO.File]::Exists($backupPath)) {
            try { [System.IO.File]::Delete($backupPath) } catch { }
        }
    }
}

function Test-PublicBetaApplicationUpdaterEvidence {
    param(
        [Parameter(Mandatory)][object]$Environment,
        [Parameter(Mandatory)][object]$Check,
        [AllowNull()][string]$EnvironmentDirectory
    )
    $reasons = @()
    if (-not (Test-DeskPetSchemaVersionOne -InputObject $Environment)) {
        $reasons += 'schemaVersion=invalid'
    }
    $evidenceType = [string](Get-ObjectPropertyValue $Environment 'evidenceType')
    $sourceReportStatus = [string](Get-ObjectPropertyValue $Environment 'sourceReportStatus')
    $environmentStatus = [string](Get-ObjectPropertyValue $Environment 'status')
    $checkStatus = [string](Get-ObjectPropertyValue $Check 'status')
    if ($evidenceType -ne 'application_updater_e2e') { $reasons += "evidenceType=$evidenceType" }
    if ($sourceReportStatus -ne 'passed') { $reasons += "sourceReportStatus=$sourceReportStatus" }
    if ($environmentStatus -ne 'passed') { $reasons += "environmentStatus=$environmentStatus" }
    if ($checkStatus -ne 'passed') { $reasons += "checkStatus=$checkStatus" }
    $sourceReportFile = [string](Get-ObjectPropertyValue $Environment 'sourceReportFile')
    $sourceReportSha256 = [string](Get-ObjectPropertyValue $Environment 'sourceReportSha256')
    $expectedSourceReportFile = [System.IO.Path]::Combine('raw', 'application-updater-result.json')
    if (-not [string]::Equals($sourceReportFile, $expectedSourceReportFile, [StringComparison]::OrdinalIgnoreCase)) {
        $reasons += 'sourceReportFile=missing-or-invalid'
    }
    if ($sourceReportSha256 -notmatch '^[A-Fa-f0-9]{64}$') { $reasons += 'sourceReportSha256=missing-or-invalid' }

    $raw = $null
    if ([string]::IsNullOrWhiteSpace($EnvironmentDirectory) -or -not [System.IO.Path]::IsPathRooted($EnvironmentDirectory)) {
        $reasons += 'sourceReportDirectory=missing-or-invalid'
    } elseif ($reasons -notcontains 'sourceReportFile=missing-or-invalid') {
        $environmentRoot = [System.IO.Path]::GetFullPath($EnvironmentDirectory).TrimEnd('\', '/')
        $rawPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($environmentRoot, $sourceReportFile))
        if (-not $rawPath.StartsWith($environmentRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            $reasons += 'sourceReportFile=outside-environment'
        } elseif (-not [System.IO.File]::Exists($rawPath)) {
            $reasons += 'sourceReport=missing'
        } else {
            $actualRawHash = (Get-FileHash -LiteralPath $rawPath -Algorithm SHA256).Hash
            if (-not [string]::Equals($actualRawHash, $sourceReportSha256, [StringComparison]::OrdinalIgnoreCase)) {
                $reasons += 'sourceReportSha256=mismatch'
            }
            try { $raw = Get-Content -LiteralPath $rawPath -Raw -Encoding UTF8 | ConvertFrom-Json }
            catch { $reasons += 'sourceReport=invalid-json' }
        }
    }

    if ($null -ne $raw) {
        if (-not (Test-DeskPetSchemaVersionOne -InputObject $raw)) { $reasons += 'raw.schemaVersion=invalid' }
        if ([string](Get-ObjectPropertyValue $raw 'evidenceType') -ne 'application_updater_e2e') { $reasons += 'raw.evidenceType=invalid' }
        if ([string](Get-ObjectPropertyValue $raw 'status') -ne 'passed') { $reasons += 'raw.status=not-passed' }
        if ([string](Get-ObjectPropertyValue $raw 'phase') -ne 'completed') { $reasons += 'raw.phase=not-completed' }
        $whatIfValue = Get-ObjectPropertyValue $raw 'whatIf'
        if ($whatIfValue -isnot [bool] -or [bool]$whatIfValue) { $reasons += 'raw.whatIf=invalid' }
        $failureProperty = $raw.PSObject.Properties['failure']
        if ($null -eq $failureProperty -or $null -ne $failureProperty.Value) { $reasons += 'raw.failure=not-null' }
        if ([string](Get-ObjectPropertyValue $raw 'finalProbeStatus') -ne 'passed') { $reasons += 'raw.finalProbeStatus=invalid' }
        $executionAllowed = Get-ObjectPropertyValue $raw 'currentInstallerExecutionAllowed'
        if ($executionAllowed -isnot [bool] -or [bool]$executionAllowed) { $reasons += 'raw.currentInstallerExecutionAllowed=invalid' }
        $executions = @((Get-ObjectPropertyValue $raw 'installerExecutions'))
        if ($executions.Count -ne 1 -or [string](Get-ObjectPropertyValue $executions[0] 'role') -ne 'version_a') {
            $reasons += 'raw.installerExecutions=not-version-a-only'
        }
        $previousInstallerHash = [string](Get-ObjectPropertyValue $raw 'previousInstallerSha256')
        if ($previousInstallerHash -notmatch '^[A-Fa-f0-9]{64}$' -or $executions.Count -ne 1 -or
            -not [string]::Equals([string](Get-ObjectPropertyValue $executions[0] 'sha256'), $previousInstallerHash, [StringComparison]::OrdinalIgnoreCase)) {
            $reasons += 'raw.previousInstallerSha256=execution-mismatch'
        }
        $roles = @((Get-ObjectPropertyValue $raw 'cryptographicallyVerifiedArtifactRoles') | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        if ($roles.Count -ne 2 -or $roles -notcontains 'version_a' -or $roles -notcontains 'version_b') {
            $reasons += 'raw.cryptographicallyVerifiedArtifactRoles=incomplete'
        }
        foreach ($propertyName in @('endpointCandidateBinding','uiPendingTargetObserved','uiConfirmedTargetObserved','uiPendingClearedAfterConfirmation','uiOrderedTransitionObserved')) {
            $propertyValue = Get-ObjectPropertyValue $raw $propertyName
            if ($propertyValue -isnot [bool] -or -not [bool]$propertyValue) { $reasons += "raw.$propertyName=not-true" }
        }
        $environmentArtifact = Get-ObjectPropertyValue $Environment 'artifact'
        $environmentInstallerHash = [string](Get-ObjectPropertyValue $environmentArtifact 'installerSha256')
        $rawInstallerHash = [string](Get-ObjectPropertyValue $raw 'currentInstallerSha256')
        if ([string]::IsNullOrWhiteSpace($environmentInstallerHash) -or
            -not [string]::Equals($environmentInstallerHash, $rawInstallerHash, [StringComparison]::OrdinalIgnoreCase)) {
            $reasons += 'raw.currentInstallerSha256=summary-mismatch'
        }
        if ([string](Get-ObjectPropertyValue $raw 'currentVersion') -ne [string](Get-ObjectPropertyValue $Environment 'expectedVersion')) {
            $reasons += 'raw.currentVersion=summary-mismatch'
        }
        if ([string](Get-ObjectPropertyValue $raw 'remoteLatestSha256') -notmatch '^[A-Fa-f0-9]{64}$') {
            $reasons += 'raw.remoteLatestSha256=missing-or-invalid'
        }
        if ([string](Get-ObjectPropertyValue $raw 'remoteArtifactSignatureSha256') -notmatch '^[A-Fa-f0-9]{64}$') {
            $reasons += 'raw.remoteArtifactSignatureSha256=missing-or-invalid'
        }
        if ([string](Get-ObjectPropertyValue $raw 'publicKeyFingerprint') -notmatch '^[A-Fa-f0-9]{64}$') {
            $reasons += 'raw.publicKeyFingerprint=missing-or-invalid'
        }
        $environmentInstallerFile = [string](Get-ObjectPropertyValue $environmentArtifact 'installerFile')
        $currentReferenceFile = [string](Get-ObjectPropertyValue $raw 'currentInstallerReferenceFile')
        $remoteArtifactFile = [string](Get-ObjectPropertyValue $raw 'remoteArtifactFile')
        if ([string]::IsNullOrWhiteSpace($environmentInstallerFile) -or
            -not [string]::Equals($currentReferenceFile, $environmentInstallerFile, [StringComparison]::Ordinal) -or
            -not [string]::Equals($remoteArtifactFile, $environmentInstallerFile, [StringComparison]::Ordinal)) {
            $reasons += 'raw.remoteArtifactFile=summary-mismatch'
        }
        $environmentSize = 0L
        $remoteSize = 0L
        if (-not [long]::TryParse([string](Get-ObjectPropertyValue $environmentArtifact 'sizeBytes'), [ref]$environmentSize) -or
            -not [long]::TryParse([string](Get-ObjectPropertyValue $raw 'remoteArtifactSizeBytes'), [ref]$remoteSize) -or
            $environmentSize -le 0 -or $remoteSize -ne $environmentSize) {
            $reasons += 'raw.remoteArtifactSizeBytes=summary-mismatch'
        }
        $rawChecks = @((Get-ObjectPropertyValue $raw 'checks'))
        $requiredChecks = @(
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
        )
        foreach ($requiredCheck in $requiredChecks) {
            $matches = @($rawChecks | Where-Object {
                [string](Get-ObjectPropertyValue $_ 'name') -eq $requiredCheck -and
                (Get-ObjectPropertyValue $_ 'passed') -is [bool] -and [bool](Get-ObjectPropertyValue $_ 'passed')
            })
            if ($matches.Count -ne 1) { $reasons += "raw.check=$requiredCheck missing-or-failed" }
        }
        if (@($rawChecks | Where-Object {
            $passedValue = Get-ObjectPropertyValue $_ 'passed'
            $passedValue -isnot [bool] -or -not [bool]$passedValue
        }).Count) {
            $reasons += 'raw.checks=contains-non-passing-check'
        }
    }
    [pscustomobject]@{ Valid=$reasons.Count -eq 0; Reasons=@($reasons) }
}

function ConvertTo-PublicBetaSafeFailureMessage {
    param(
        [AllowNull()][string]$Message,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )
    if ([string]::IsNullOrWhiteSpace($Message)) { return 'No failure message was supplied.' }
    $redacted = $Message
    $knownLocations = @(
        [pscustomobject]@{ Path=$RepositoryRoot; Token='%REPOSITORY%' },
        [pscustomobject]@{ Path=$env:LOCALAPPDATA; Token='%LOCALAPPDATA%' },
        [pscustomobject]@{ Path=$env:APPDATA; Token='%APPDATA%' },
        [pscustomobject]@{ Path=$env:USERPROFILE; Token='%USERPROFILE%' },
        [pscustomobject]@{ Path=$env:TEMP; Token='%TEMP%' },
        [pscustomobject]@{ Path=$env:ProgramData; Token='%PROGRAMDATA%' },
        [pscustomobject]@{ Path=$env:SystemRoot; Token='%SYSTEMROOT%' },
        [pscustomobject]@{ Path=$env:ProgramFiles; Token='%PROGRAMFILES%' },
        [pscustomobject]@{ Path=${env:ProgramFiles(x86)}; Token='%PROGRAMFILES_X86%' }
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Path) } |
        Sort-Object { ([string]$_.Path).Length } -Descending
    foreach ($knownLocation in $knownLocations) {
        $normalized = ([string]$knownLocation.Path).TrimEnd('\')
        $redacted = [regex]::Replace(
            $redacted,
            [regex]::Escape($normalized),
            [string]$knownLocation.Token,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    # Any absolute Windows path that is not under a known safe token is reduced
    # to a role marker. Failure phase and exception type remain separate fields.
    $redacted = [regex]::Replace($redacted, '(?i)file:(?:/{2,3}|\\\\)[^\r\n\s"'']+', '<absolute-file-uri>')
    $redacted = [regex]::Replace($redacted, '(?i)(?<![%A-Za-z0-9_])[A-Z]:[/\\][^\r\n]*', '<absolute-path>')
    $redacted = [regex]::Replace($redacted, '(?<![:/\\])(?:\\\\|//)[^\r\n]+', '<absolute-unc-path>')
    return $redacted
}

function Resolve-PublicBetaUpdaterArtifactSet {
    param(
        [Parameter(Mandatory)][ValidateSet('version_a','version_b')][string]$Role,
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$ExpectedInstallerSha256
    )
    $artifactFile = [string](Get-ObjectPropertyValue $Manifest 'artifactFile')
    $signatureFile = [string](Get-ObjectPropertyValue $Manifest 'signatureFile')
    foreach ($fileName in @($artifactFile, $signatureFile)) {
        if ([string]::IsNullOrWhiteSpace($fileName) -or [System.IO.Path]::IsPathRooted($fileName) -or
            $fileName -ne [System.IO.Path]::GetFileName($fileName) -or $fileName -in @('.', '..') -or
            $fileName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "$Role updater manifest contains an unsafe artifact filename."
        }
    }
    if (-not [string]::Equals($signatureFile, $artifactFile + '.sig', [StringComparison]::Ordinal)) {
        throw "$Role updater signature filename must be the artifact filename plus .sig."
    }
    $manifestDirectory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($ManifestPath))
    $artifactPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($manifestDirectory, $artifactFile))
    $signaturePath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($manifestDirectory, $signatureFile))
    if (-not [System.IO.File]::Exists($artifactPath)) { throw "$Role updater artifact is missing: $artifactPath" }
    if (-not [System.IO.File]::Exists($signaturePath)) { throw "$Role updater signature is missing: $signaturePath" }
    $artifactSha256 = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash
    $manifestSha256 = [string](Get-ObjectPropertyValue $Manifest 'artifactSha256')
    if ($artifactSha256 -ne $ExpectedInstallerSha256 -or $manifestSha256 -ne $ExpectedInstallerSha256) {
        throw "$Role updater artifact, manifest, and installer hashes do not match."
    }
    [pscustomobject]@{
        Role=$Role
        ArtifactFile=$artifactFile
        SignatureFile=$signatureFile
        ArtifactPath=$artifactPath
        SignaturePath=$signaturePath
        ArtifactSha256=$artifactSha256
    }
}

function Assert-PublicBetaUpdaterArtifactSignatures {
    param(
        [Parameter(Mandatory)][object[]]$ArtifactSets,
        [Parameter(Mandatory)][string]$PublicKeyPath,
        [scriptblock]$SignatureVerifier = {
            param($ArtifactPath, $SignaturePath, $PublicKeyPath)
            Test-DeskPetUpdaterArtifactSignature -ArtifactPath $ArtifactPath -SignaturePath $SignaturePath -PublicKeyPath $PublicKeyPath
        }
    )
    $roles = @($ArtifactSets | ForEach-Object { [string](Get-ObjectPropertyValue $_ 'Role') })
    if ($ArtifactSets.Count -ne 2 -or $roles -notcontains 'version_a' -or $roles -notcontains 'version_b') {
        throw 'Application updater QA requires exactly one version A and one version B artifact set.'
    }
    foreach ($artifactSet in $ArtifactSets) {
        $verified = [bool](& $SignatureVerifier `
            (Get-ObjectPropertyValue $artifactSet 'ArtifactPath') `
            (Get-ObjectPropertyValue $artifactSet 'SignaturePath') `
            $PublicKeyPath)
        if (-not $verified) {
            throw "$([string](Get-ObjectPropertyValue $artifactSet 'Role')) updater artifact signature verification failed."
        }
    }
}

function Invoke-PublicBetaRemoteLatestBinding {
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$CurrentVersion,
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [Parameter(Mandatory)][string]$Platform,
        [Parameter(Mandatory)][string]$ExpectedDownloadUrl,
        [Parameter(Mandatory)][string]$ArtifactPath,
        [Parameter(Mandatory)][string]$SignaturePath,
        [Parameter(Mandatory)][string]$PublicKeyPath,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [scriptblock]$Downloader,
        [scriptblock]$LatestValidator
    )
    $endpointUri = $null
    if (-not [Uri]::TryCreate($Endpoint, [UriKind]::Absolute, [ref]$endpointUri) -or $endpointUri.Scheme -ne 'https') {
        throw 'The version A updater endpoint is not an absolute HTTPS URL.'
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedDownloadUrl)) { throw 'The version B updater manifest has no download URL.' }
    if ($null -eq $Downloader) {
        $Downloader = {
            param($Uri, $Destination)
            $response = Invoke-WebRequest -Uri $Uri -OutFile $Destination -PassThru -UseBasicParsing -TimeoutSec 30 -MaximumRedirection 5
            $finalUri = $response.BaseResponse.ResponseUri
            if ($null -eq $finalUri) { $finalUri = [Uri]$Uri }
            [pscustomobject]@{ FinalUri=$finalUri.AbsoluteUri }
        }
    }
    if ($null -eq $LatestValidator) {
        $validatorPath = [System.IO.Path]::Combine($RepositoryRoot, 'scripts', 'updater', 'validate-latest-json.ps1')
        $LatestValidator = {
            param($LatestPath, $FromVersion, $ToVersion, $TargetPlatform, $CandidateArtifact, $CandidateSignature, $ProductionPublicKey)
            & $validatorPath -LatestJsonPath $LatestPath -CurrentVersion $FromVersion -ExpectedVersion $ToVersion `
                -Platform $TargetPlatform -ArtifactPath $CandidateArtifact -SignaturePath $CandidateSignature -PublicKeyPath $ProductionPublicKey
        }.GetNewClosure()
    }

    $temporaryDirectory = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'qijiang-remote-latest-' + [Guid]::NewGuid().ToString('N'))
    $latestPath = [System.IO.Path]::Combine($temporaryDirectory, 'latest.json')
    $operationFailed = $false
    try {
        [void][System.IO.Directory]::CreateDirectory($temporaryDirectory)
        $downloadResult = & $Downloader $endpointUri.AbsoluteUri $latestPath
        if (-not [System.IO.File]::Exists($latestPath)) { throw 'The updater endpoint did not produce latest.json.' }
        $latestLength = (Get-Item -LiteralPath $latestPath).Length
        if ($latestLength -le 0 -or $latestLength -gt 1048576) { throw 'The updater endpoint returned an invalid latest.json size.' }
        $finalUriText = [string](Get-ObjectPropertyValue $downloadResult 'FinalUri')
        $finalUri = $null
        if (-not [Uri]::TryCreate($finalUriText, [UriKind]::Absolute, [ref]$finalUri) -or $finalUri.Scheme -ne 'https') {
            throw 'The updater metadata request did not finish on HTTPS.'
        }
        $validationOutput = @(& $LatestValidator $latestPath $CurrentVersion $ExpectedVersion $Platform $ArtifactPath $SignaturePath $PublicKeyPath)
        $validation = if ($validationOutput.Count) { $validationOutput[-1] } else { $null }
        $cryptoValue = Get-ObjectPropertyValue $validation 'CryptographicSignatureVerified'
        if ($cryptoValue -isnot [bool] -or -not [bool]$cryptoValue) {
            throw 'Remote latest.json did not cryptographically bind the candidate artifact.'
        }
        $latest = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string](Get-ObjectPropertyValue $latest 'version') -ne $ExpectedVersion) { throw 'Remote latest.json version does not match version B.' }
        $platforms = Get-ObjectPropertyValue $latest 'platforms'
        $platformProperty = if ($null -eq $platforms) { $null } else { $platforms.PSObject.Properties[$Platform] }
        if ($null -eq $platformProperty) { throw 'Remote latest.json does not contain the expected Windows platform.' }
        $entry = $platformProperty.Value
        $remoteUrl = [string](Get-ObjectPropertyValue $entry 'url')
        if (-not [string]::Equals($remoteUrl, $ExpectedDownloadUrl, [StringComparison]::Ordinal)) {
            throw 'Remote latest.json download URL does not match the version B release manifest.'
        }
        $remoteSize = 0L
        if (-not [long]::TryParse([string](Get-ObjectPropertyValue $entry 'size'), [ref]$remoteSize) -or
            $remoteSize -ne (Get-Item -LiteralPath $ArtifactPath).Length) {
            throw 'Remote latest.json artifact size does not match version B.'
        }
        $remoteSignature = [string](Get-ObjectPropertyValue $entry 'signature')
        $localSignature = [System.IO.File]::ReadAllText($SignaturePath, [System.Text.Encoding]::UTF8).Trim()
        if (-not [string]::Equals($remoteSignature, $localSignature, [StringComparison]::Ordinal)) {
            throw 'Remote latest.json signature does not match version B.'
        }
        $remoteArtifactUri = [Uri]$remoteUrl
        return [pscustomobject]@{
            Bound=$true
            LatestSha256=(Get-FileHash -LiteralPath $latestPath -Algorithm SHA256).Hash
            EndpointHost=$endpointUri.DnsSafeHost
            FinalMetadataHost=$finalUri.DnsSafeHost
            ArtifactHost=$remoteArtifactUri.DnsSafeHost
            ArtifactFile=[Uri]::UnescapeDataString([System.IO.Path]::GetFileName($remoteArtifactUri.AbsolutePath))
            ArtifactSizeBytes=$remoteSize
            SignatureSha256=Get-DeskPetStringSha256 -Value $remoteSignature
        }
    } catch {
        $operationFailed = $true
        throw
    } finally {
        if ([System.IO.Directory]::Exists($temporaryDirectory)) {
            try { [System.IO.Directory]::Delete($temporaryDirectory, $true) }
            catch { if (-not $operationFailed) { throw 'Temporary updater metadata cleanup failed.' } }
        }
    }
}

function Get-PublicBetaAutostartSnapshot {
    param(
        [AllowEmptyCollection()][object[]]$Entries,
        [Parameter(Mandatory)][string]$ExpectedExecutablePath
    )
    $expected = [System.IO.Path]::GetFullPath($ExpectedExecutablePath)
    $canonical = @()
    $allTargetExpectedExecutable = $true
    foreach ($entry in @($Entries)) {
        try {
            $parsed = ConvertFrom-NativeCommandLine -CommandLine ([string](Get-ObjectPropertyValue $entry 'Value'))
            $targetMatches = [string]::Equals([System.IO.Path]::GetFullPath($parsed.FilePath), $expected, [StringComparison]::OrdinalIgnoreCase)
        } catch { $targetMatches = $false }
        if (-not $targetMatches) { $allTargetExpectedExecutable = $false }
        $canonical += [ordered]@{
            key=[string](Get-ObjectPropertyValue $entry 'Key')
            name=[string](Get-ObjectPropertyValue $entry 'Name')
            value=[string](Get-ObjectPropertyValue $entry 'Value')
        }
    }
    $canonical = @($canonical | Sort-Object key,name,value)
    [pscustomobject]@{
        Count=$canonical.Count
        Fingerprint=Get-DeskPetStringSha256 -Value ($canonical | ConvertTo-Json -Depth 5 -Compress)
        AllTargetExpectedExecutable=$allTargetExpectedExecutable
    }
}

function Get-PublicBetaStartMenuSnapshot {
    param(
        [AllowEmptyCollection()][object[]]$Entries,
        [Parameter(Mandatory)][string]$ExpectedExecutablePath,
        [scriptblock]$ShortcutTargetResolver
    )
    if ($null -eq $ShortcutTargetResolver) {
        $ShortcutTargetResolver = {
            param($ShortcutPath)
            $shell = New-Object -ComObject WScript.Shell
            try { return [string]$shell.CreateShortcut($ShortcutPath).TargetPath }
            finally { if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } }
        }
    }
    $expected = [System.IO.Path]::GetFullPath($ExpectedExecutablePath)
    $canonical = @()
    $allTargetExpectedExecutable = $true
    foreach ($entry in @($Entries)) {
        $fullName = [string](Get-ObjectPropertyValue $entry 'FullName')
        try {
            $target = & $ShortcutTargetResolver $fullName
            $targetMatches = -not [string]::IsNullOrWhiteSpace([string]$target) -and
                [string]::Equals([System.IO.Path]::GetFullPath([string]$target), $expected, [StringComparison]::OrdinalIgnoreCase)
        } catch { $targetMatches = $false; $target = $null }
        if (-not $targetMatches) { $allTargetExpectedExecutable = $false }
        $canonical += [ordered]@{ path=[System.IO.Path]::GetFullPath($fullName); name=[System.IO.Path]::GetFileName($fullName); target=[string]$target }
    }
    $canonical = @($canonical | Sort-Object name,target)
    [pscustomobject]@{
        Count=$canonical.Count
        Fingerprint=Get-DeskPetStringSha256 -Value ($canonical | ConvertTo-Json -Depth 4 -Compress)
        AllTargetExpectedExecutable=$allTargetExpectedExecutable
    }
}

function Get-PublicBetaSafeCharacterPackageFiles {
    param([Parameter(Mandatory)][string]$CharacterDirectory)
    $root = [System.IO.Path]::GetFullPath($CharacterDirectory)
    $directories = New-Object 'System.Collections.Generic.Queue[string]'
    $files = New-Object 'System.Collections.Generic.List[string]'
    $directories.Enqueue($root)
    while ($directories.Count -gt 0) {
        $directory = $directories.Dequeue()
        foreach ($entryPath in [System.IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $fullPath = [System.IO.Path]::GetFullPath($entryPath)
            if (-not $fullPath.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The selected imported character contains a path outside its package.'
            }
            $attributes = [System.IO.File]::GetAttributes($fullPath)
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The selected imported character contains a reparse point.'
            }
            if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $directories.Enqueue($fullPath)
            } else {
                $files.Add($fullPath)
            }
        }
    }
    return @($files)
}

function Get-PublicBetaInstalledCharacterSnapshot {
    param(
        [Parameter(Mandatory)][string]$CharacterId,
        [Parameter(Mandatory)][string]$SkinId
    )
    if ($CharacterId -notmatch '^[a-z0-9_][a-z0-9_-]*$' -or $CharacterId -eq '_placeholder') {
        throw 'Application updater QA requires a locally imported non-placeholder character.'
    }
    $characterRoot = [System.IO.Path]::Combine($env:LOCALAPPDATA, $script:AppIdentifier, 'characters')
    $characterDirectory = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($characterRoot, $CharacterId))
    if (-not $characterDirectory.StartsWith([System.IO.Path]::GetFullPath($characterRoot).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not [System.IO.Directory]::Exists($characterDirectory)) { throw 'The selected imported character directory does not exist.' }
    if (([System.IO.File]::GetAttributes($characterDirectory) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The selected imported character directory is a reparse point.'
    }
    # Enumerate one directory level at a time and reject every reparse point
    # before reading manifests, display assets, or animation frames.
    $packageFiles = @(Get-PublicBetaSafeCharacterPackageFiles -CharacterDirectory $characterDirectory)
    $manifestPath = [System.IO.Path]::Combine($characterDirectory, 'manifest.json')
    $framesPath = [System.IO.Path]::Combine($characterDirectory, 'frames.json')
    if (-not [System.IO.File]::Exists($manifestPath) -or -not [System.IO.File]::Exists($framesPath)) {
        throw 'The selected imported character is missing manifest.json or frames.json.'
    }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $frames = Get-Content -LiteralPath $framesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch { throw 'The selected imported character metadata cannot be loaded.' }
    if ([string](Get-ObjectPropertyValue $manifest 'id') -ne $CharacterId) { throw 'The selected imported character ID does not match its manifest.' }
    $skins = Get-ObjectPropertyValue $manifest 'skins'
    if ($null -eq $skins -or $null -eq $skins.PSObject.Properties[$SkinId]) { throw 'The selected character skin is missing.' }
    $animations = Get-ObjectPropertyValue $manifest 'animations'
    $frameAnimations = Get-ObjectPropertyValue $frames 'animations'
    if ($null -eq $animations -or $null -eq $frameAnimations) { throw 'The selected imported character has no loadable animations.' }
    foreach ($frameProperty in @($frameAnimations.PSObject.Properties)) {
        if ($null -eq $animations.PSObject.Properties[$frameProperty.Name]) { throw 'The selected imported character frame index contains an undeclared animation.' }
    }
    $frameSize = Get-ObjectPropertyValue $manifest 'frameSize'
    $expectedFrameWidth = [int](Get-ObjectPropertyValue $frameSize 'width')
    $expectedFrameHeight = [int](Get-ObjectPropertyValue $frameSize 'height')
    if ($expectedFrameWidth -le 0 -or $expectedFrameHeight -le 0) { throw 'The selected imported character frame size is invalid.' }
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    foreach ($displayAssetName in @('preview','icon')) {
        $displayAsset = [string](Get-ObjectPropertyValue $manifest $displayAssetName)
        if ([string]::IsNullOrWhiteSpace($displayAsset)) { continue }
        if ([System.IO.Path]::IsPathRooted($displayAsset) -or $displayAsset -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "The selected imported character contains an unsafe $displayAssetName path."
        }
        $displayAssetPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($characterDirectory, $displayAsset))
        if (-not $displayAssetPath.StartsWith($characterDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
            -not [System.IO.File]::Exists($displayAssetPath)) {
            throw "The selected imported character is missing its declared $displayAssetName asset."
        }
    }
    foreach ($animationProperty in @($animations.PSObject.Properties)) {
        $frameProperty = $frameAnimations.PSObject.Properties[$animationProperty.Name]
        $relativeFrames = if ($null -eq $frameProperty) { @() } else { @($frameProperty.Value) }
        if (-not $relativeFrames.Count) { throw 'The selected imported character has an animation with no frames.' }
        foreach ($relativeFrame in $relativeFrames) {
            $relativeText = [string]$relativeFrame
            if ([string]::IsNullOrWhiteSpace($relativeText) -or [System.IO.Path]::IsPathRooted($relativeText) -or $relativeText -match '(^|[\\/])\.\.([\\/]|$)') {
                throw 'The selected imported character contains an unsafe frame path.'
            }
            $framePath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($characterDirectory, $relativeText))
            if (-not $framePath.StartsWith($characterDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
                -not [System.IO.File]::Exists($framePath)) { throw 'The selected imported character contains a missing frame.' }
            $stream = [System.IO.File]::OpenRead($framePath)
            try {
                $header = New-Object byte[] 8
                if ($stream.Read($header, 0, 8) -ne 8 -or [BitConverter]::ToString($header) -ne '89-50-4E-47-0D-0A-1A-0A') {
                    throw 'The selected imported character contains an unreadable PNG frame.'
                }
            } finally { $stream.Dispose() }
            $image = $null
            try {
                $image = [System.Drawing.Image]::FromFile($framePath)
                if ($image.Width -ne $expectedFrameWidth -or $image.Height -ne $expectedFrameHeight) {
                    throw 'The selected imported character contains a frame with unexpected dimensions.'
                }
            } catch { throw 'The selected imported character contains a PNG frame that cannot be decoded.' }
            finally { if ($null -ne $image) { $image.Dispose() } }
        }
    }
    if (-not $packageFiles.Count) { throw 'The selected imported character package is empty.' }
    $fileFacts = @($packageFiles | Sort-Object -Unique | ForEach-Object {
        $relativeName = $_.Substring($characterDirectory.Length).TrimStart('\', '/').Replace('\', '/')
        [ordered]@{ name=$relativeName; length=(Get-Item -LiteralPath $_).Length; sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
    })
    [pscustomobject]@{
        CharacterId=$CharacterId
        SkinId=$SkinId
        FileCount=$fileFacts.Count
        Fingerprint=Get-DeskPetStringSha256 -Value ($fileFacts | ConvertTo-Json -Depth 5 -Compress)
    }
}

function Get-DeskPetPreservedSettingsSnapshot {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { throw 'The settings file does not exist.' }
    $document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    # The native settings writer stores the application settings beneath a
    # top-level `settings` property. Continue accepting the historical flat
    # fixture shape so older lifecycle evidence can still be inspected.
    $settingsProperty = $document.PSObject.Properties['settings']
    $settings = if ($null -ne $settingsProperty) { $settingsProperty.Value } else { $document }
    if ($null -eq $settings -or $null -eq $settings.PSObject) {
        throw 'The settings file does not contain a readable settings object.'
    }
    $propertyNames = @(
        'position','monitorName','scale','opacity','characterId','skinId','alwaysOnTop','autostart',
        'animationsPaused','volume','hideInFullscreen','developerPanel','interactionsEnabled','facing',
        'automaticUpdateChecks','updateSkippedVersion'
    )
    $preserved = [ordered]@{}
    foreach ($propertyName in $propertyNames) {
        if ($null -eq $settings.PSObject.Properties[$propertyName]) {
            throw "The settings file is missing the preserved property: $propertyName"
        }
        $preserved[$propertyName] = $settings.PSObject.Properties[$propertyName].Value
    }
    $canonical = $preserved | ConvertTo-Json -Depth 8 -Compress
    [pscustomobject]@{
        Fingerprint=Get-DeskPetStringSha256 $canonical
        CharacterId=[string]$preserved.characterId
        SkinId=[string]$preserved.skinId
        Autostart=[bool]$preserved.autostart
        PendingUpdateVersion=[string](Get-ObjectPropertyValue $settings 'pendingUpdateVersion')
        LastConfirmedUpdateVersion=[string](Get-ObjectPropertyValue $settings 'lastConfirmedUpdateVersion')
    }
}

function Wait-PublicBetaApplicationUpdaterTransition {
    param(
        [Parameter(Mandatory)][string]$PreviousVersion,
        [Parameter(Mandatory)][string]$CurrentVersion,
        [Parameter(Mandatory)][int[]]$InitialProcessIds,
        [ValidateRange(30, 1800)][int]$TimeoutSeconds = 600,
        [ValidateRange(100, 2000)][int]$PollIntervalMilliseconds = 500,
        [Parameter(Mandatory)][scriptblock]$Probe,
        [scriptblock]$Delay = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds },
        [AllowNull()][scriptblock]$GetElapsedMilliseconds
    )
    if (-not $InitialProcessIds.Count) { throw 'At least one version A process id is required.' }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($null -eq $GetElapsedMilliseconds) {
        $GetElapsedMilliseconds = { $stopwatch.ElapsedMilliseconds }.GetNewClosure()
    }
    $timeoutMilliseconds = [int64]$TimeoutSeconds * 1000
    $attempts = 0
    $previousVersionObserved = $false
    $pendingTargetObserved = $false
    $confirmedTargetObserved = $false
    $pendingClearedAfterConfirmation = $false
    $restartObservedAfterPending = $false
    $transitionPhase = 'awaiting-version-a-pending'
    $pendingObservedAttempt = $null
    $restartObservedAttempt = $null
    $confirmationObservedAttempt = $null
    while ($true) {
        $attempts++
        $state = & $Probe
        $versions = @((Get-ObjectPropertyValue $state 'Versions') | ForEach-Object { [string]$_ })
        $processIds = @((Get-ObjectPropertyValue $state 'ProcessIds') | ForEach-Object { [int]$_ })
        $recordCount = [int](Get-ObjectPropertyValue $state 'RecordCount')
        $pendingUpdateVersion = [string](Get-ObjectPropertyValue $state 'PendingUpdateVersion')
        $lastConfirmedUpdateVersion = [string](Get-ObjectPropertyValue $state 'LastConfirmedUpdateVersion')
        if ($versions -contains $PreviousVersion) { $previousVersionObserved = $true }
        $oldProcessIdsRemaining = @($processIds | Where-Object { $InitialProcessIds -contains $_ })
        $newProcessIds = @($processIds | Where-Object { $InitialProcessIds -notcontains $_ })
        $oldProcessesExited = $oldProcessIdsRemaining.Count -eq 0
        $currentVersionObserved = $versions -contains $CurrentVersion
        $previousVersionRemoved = $versions -notcontains $PreviousVersion

        if ($transitionPhase -eq 'awaiting-version-a-pending') {
            $pendingWasWrittenByVersionA = $pendingUpdateVersion -eq $CurrentVersion -and
                $versions -contains $PreviousVersion -and -not $currentVersionObserved -and
                $oldProcessIdsRemaining.Count -gt 0 -and $recordCount -eq 1 -and
                $lastConfirmedUpdateVersion -ne $CurrentVersion
            if ($pendingWasWrittenByVersionA) {
                $pendingTargetObserved = $true
                $pendingObservedAttempt = $attempts
                $transitionPhase = 'pending-observed-in-version-a'
            }
        } elseif ($transitionPhase -eq 'pending-observed-in-version-a') {
            $restartStateObserved = $currentVersionObserved -and $previousVersionRemoved -and
                $oldProcessesExited -and $newProcessIds.Count -gt 0 -and $recordCount -eq 1
            if ($restartStateObserved) {
                $restartObservedAfterPending = $true
                $restartObservedAttempt = $attempts
                $transitionPhase = 'version-b-restart-observed'
            }
        } elseif ($transitionPhase -eq 'version-b-restart-observed') {
            $confirmationStateObserved = $currentVersionObserved -and $previousVersionRemoved -and
                $oldProcessesExited -and $newProcessIds.Count -gt 0 -and $recordCount -eq 1 -and
                $lastConfirmedUpdateVersion -eq $CurrentVersion -and [string]::IsNullOrWhiteSpace($pendingUpdateVersion)
            if ($confirmationStateObserved) {
                $confirmedTargetObserved = $true
                $pendingClearedAfterConfirmation = $true
                $confirmationObservedAttempt = $attempts
                $transitionPhase = 'confirmed-in-version-b'
            }
        }
        $orderedTransitionObserved = $pendingTargetObserved -and $restartObservedAfterPending -and
            $confirmedTargetObserved -and $pendingClearedAfterConfirmation -and
            $pendingObservedAttempt -lt $restartObservedAttempt -and $restartObservedAttempt -lt $confirmationObservedAttempt
        $complete = $previousVersionObserved -and $currentVersionObserved -and $previousVersionRemoved -and
            $oldProcessesExited -and $newProcessIds.Count -gt 0 -and $recordCount -eq 1 -and $orderedTransitionObserved
        $elapsedMilliseconds = [int64](& $GetElapsedMilliseconds)
        if ($complete -or $elapsedMilliseconds -ge $timeoutMilliseconds) {
            $stopwatch.Stop()
            return [pscustomobject]@{
                Complete=$complete
                TimedOut=-not $complete
                ElapsedMilliseconds=$elapsedMilliseconds
                ElapsedSeconds=[Math]::Round($elapsedMilliseconds / 1000, 3)
                Attempts=$attempts
                PreviousVersionObserved=$previousVersionObserved
                CurrentVersionObserved=$currentVersionObserved
                PreviousVersionRemoved=$previousVersionRemoved
                OldProcessesExited=$oldProcessesExited
                PendingTargetObserved=$pendingTargetObserved
                RestartObservedAfterPending=$restartObservedAfterPending
                ConfirmedTargetObserved=$confirmedTargetObserved
                PendingClearedAfterConfirmation=$pendingClearedAfterConfirmation
                OrderedTransitionObserved=$orderedTransitionObserved
                TransitionPhase=$transitionPhase
                PendingObservedAttempt=$pendingObservedAttempt
                RestartObservedAttempt=$restartObservedAttempt
                ConfirmationObservedAttempt=$confirmationObservedAttempt
                NewProcessIds=@($newProcessIds)
                State=$state
            }
        }
        $remainingMilliseconds = $timeoutMilliseconds - $elapsedMilliseconds
        & $Delay ([int][Math]::Min($PollIntervalMilliseconds, $remainingMilliseconds))
    }
}
