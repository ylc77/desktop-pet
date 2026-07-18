[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$updaterTools = [System.IO.Path]::Combine($repositoryRoot, 'scripts', 'updater')
. ([System.IO.Path]::Combine($updaterTools, 'common.ps1'))
. ([System.IO.Path]::Combine($updaterTools, 'github-release-common.ps1'))

$results = @()
function Add-Test([string]$Name, [bool]$Passed, [string]$Details) {
    $script:results += [pscustomobject]@{ Name=$Name; Passed=$Passed; Details=$Details }
}
function Test-Equal([string]$Name, [object]$Expected, [object]$Actual) {
    Add-Test $Name ($Expected -eq $Actual) "expected=$Expected; actual=$Actual"
}
function Test-True([string]$Name, [bool]$Actual, [string]$Details) {
    Add-Test $Name $Actual $Details
}
function Test-Throws([string]$Name, [scriptblock]$Action, [string]$Pattern) {
    try { & $Action; Add-Test $Name $false 'No exception was thrown.' }
    catch { Add-Test $Name ($_.Exception.Message -match $Pattern) $_.Exception.Message }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$temporaryRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'qijiang-github-hosting-tests-' + [Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($temporaryRoot)
try {
    $configurationPath = [System.IO.Path]::Combine($repositoryRoot, 'config', 'updater.github-releases.json')
    $configurationText = Get-Content -LiteralPath $configurationPath -Raw -Encoding UTF8
    $configuration = Read-GitHubUpdaterHostingConfiguration -LiteralPath $configurationPath
    Test-Equal 'Formal GitHub hosting configuration is enabled' $true ([bool]$configuration.enabled)
    Test-Equal 'Configured GitHub repository is exact' 'ylc77/desktop-pet' ([string]$configuration.repository)
    Test-Equal 'Beta metadata uses the exact reviewed GitHub Releases latest asset path' 'https://github.com/ylc77/desktop-pet/releases/latest/download/latest.json' ([string]$configuration.metadata.endpoint)
    Test-Equal 'GitHub Releases metadata is owner-confirmed' $true ([bool]$configuration.metadata.ownerConfirmed)
    Test-Equal 'Hosting configuration has no key or credential fields' $false ([bool]($configurationText -match '(?i)"(?:privateKey|publicKey|password|accessToken|apiToken|secret)"\s*:'))
    Test-Equal 'Hosting configuration uses the stable releases/latest asset route' $true ([bool]($configurationText -match '(?i)/releases/latest/download/latest\.json'))
    $updaterOverlay = Get-Content -LiteralPath ([System.IO.Path]::Combine($repositoryRoot, 'src-tauri', 'tauri.updater.conf.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Equal 'Tracked updater overlay enables Tauri updater artifacts' $true ([bool]$updaterOverlay.bundle.createUpdaterArtifacts)
    Test-Equal 'Tracked updater overlay uses the production endpoint' ([string]$configuration.metadata.endpoint) ([string]$updaterOverlay.plugins.updater.endpoints[0])
    Test-Equal 'Tracked updater overlay embeds the production public-key fingerprint' '843139244142865CA6E45A0F6D77A2128D3CC0486792BD5388BBC7B753B35552' `
        (Get-UpdaterPublicKeyTextFingerprint -PublicKeyText ([string]$updaterOverlay.plugins.updater.pubkey))
    $baseTauriConfiguration = Get-Content -LiteralPath ([System.IO.Path]::Combine($repositoryRoot, 'src-tauri', 'tauri.conf.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    $placeholderManifest = Get-Content -LiteralPath ([System.IO.Path]::Combine($repositoryRoot, 'public', 'characters', '_placeholder', 'manifest.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Equal 'Updater enablement preserves the application identifier' 'dev.deskpet.framework' ([string]$baseTauriConfiguration.identifier)
    Test-Equal 'Updater enablement preserves character schemaVersion 1' 1 ([int]$placeholderManifest.schemaVersion)

    $booleanCases = @(
        @{ Name='enabled'; Apply={ param($value); $value.enabled = 'false' } },
        @{ Name='draft'; Apply={ param($value); $value.release.draft = 'false' } },
        @{ Name='prerelease'; Apply={ param($value); $value.release.prerelease = 'false' } },
        @{ Name='immutableVersionedAssets'; Apply={ param($value); $value.release.immutableVersionedAssets = 'false' } },
        @{ Name='publishAfterRemoteVerification'; Apply={ param($value); $value.metadata.publishAfterRemoteVerification = 'false' } },
        @{ Name='ownerConfirmed'; Apply={ param($value); $value.metadata.ownerConfirmed = 'false' } }
    )
    foreach ($booleanCase in $booleanCases) {
        $invalidBooleanPath = [System.IO.Path]::Combine($temporaryRoot, 'invalid-' + [string]$booleanCase.Name + '.json')
        $invalidBooleanConfiguration = $configurationText | ConvertFrom-Json
        & $booleanCase.Apply $invalidBooleanConfiguration
        [System.IO.File]::WriteAllText($invalidBooleanPath, ($invalidBooleanConfiguration | ConvertTo-Json -Depth 8), $utf8NoBom)
        $invalidBooleanAction = {
            Read-GitHubUpdaterHostingConfiguration -LiteralPath $invalidBooleanPath
        }.GetNewClosure()
        Test-Throws ("String false is rejected for JSON Boolean " + [string]$booleanCase.Name) $invalidBooleanAction 'JSON Boolean'
    }
    $prereleaseConfiguration = $configurationText | ConvertFrom-Json
    $prereleaseConfiguration.release.prerelease = $true
    $prereleaseConfigurationPath = [System.IO.Path]::Combine($temporaryRoot, 'invalid-prerelease-routing.json')
    [System.IO.File]::WriteAllText($prereleaseConfigurationPath, ($prereleaseConfiguration | ConvertTo-Json -Depth 8), $utf8NoBom)
    Test-Throws 'releases/latest beta routing rejects the GitHub prerelease flag' {
        Read-GitHubUpdaterHostingConfiguration -LiteralPath $prereleaseConfigurationPath
    } 'prerelease flag|releases/latest'
    $stringSchemaConfiguration = $configurationText | ConvertFrom-Json
    $stringSchemaConfiguration.schemaVersion = '1'
    $stringSchemaPath = [System.IO.Path]::Combine($temporaryRoot, 'string-schema.json')
    [System.IO.File]::WriteAllText($stringSchemaPath, ($stringSchemaConfiguration | ConvertTo-Json -Depth 8), $utf8NoBom)
    Test-Throws 'Hosting schemaVersion must be a JSON integer' {
        Read-GitHubUpdaterHostingConfiguration -LiteralPath $stringSchemaPath
    } 'schema'
    $unknownTopLevelConfiguration = $configurationText | ConvertFrom-Json
    $unknownTopLevelConfiguration | Add-Member -NotePropertyName 'debugMode' -NotePropertyValue $false
    $unknownTopLevelPath = [System.IO.Path]::Combine($temporaryRoot, 'unknown-top-level.json')
    [System.IO.File]::WriteAllText($unknownTopLevelPath, ($unknownTopLevelConfiguration | ConvertTo-Json -Depth 8), $utf8NoBom)
    Test-Throws 'Hosting configuration rejects unknown top-level fields' {
        Read-GitHubUpdaterHostingConfiguration -LiteralPath $unknownTopLevelPath
    } 'exactly|unknown'
    $unknownNestedConfiguration = $configurationText | ConvertFrom-Json
    $unknownNestedConfiguration.metadata | Add-Member -NotePropertyName 'cachePolicy' -NotePropertyValue 'none'
    $unknownNestedPath = [System.IO.Path]::Combine($temporaryRoot, 'unknown-nested.json')
    [System.IO.File]::WriteAllText($unknownNestedPath, ($unknownNestedConfiguration | ConvertTo-Json -Depth 8), $utf8NoBom)
    Test-Throws 'Hosting configuration rejects unknown nested fields' {
        Read-GitHubUpdaterHostingConfiguration -LiteralPath $unknownNestedPath
    } 'exactly|unknown'
    $credentialConfiguration = $configurationText | ConvertFrom-Json
    $credentialConfiguration.metadata | Add-Member -NotePropertyName 'credential' -NotePropertyValue 'must-not-pass'
    $credentialConfigurationPath = [System.IO.Path]::Combine($temporaryRoot, 'credential-field.json')
    [System.IO.File]::WriteAllText($credentialConfigurationPath, ($credentialConfiguration | ConvertTo-Json -Depth 8), $utf8NoBom)
    Test-Throws 'Hosting configuration rejects recursive credential fields' {
        Read-GitHubUpdaterHostingConfiguration -LiteralPath $credentialConfigurationPath
    } 'sensitive|secret|unknown'
    $missingConfigurationPath = [System.IO.Path]::Combine($temporaryRoot, 'missing-hosting.json')
    try {
        Read-GitHubUpdaterHostingConfiguration -LiteralPath $missingConfigurationPath | Out-Null
        Add-Test 'Missing configuration error is path-redacted' $false 'No exception was thrown.'
    } catch {
        Add-Test 'Missing configuration error is path-redacted' (-not $_.Exception.Message.Contains($temporaryRoot)) $_.Exception.Message
    }

    $version = '0.2.1-beta.1'
    $currentVersion = '0.2.0-beta.1'
    $artifactName = (-join @([char]0x4E03,[char]0x9171,[char]0x684C,[char]0x5BA0)) + "_$version`_x64-setup.exe"
    $artifactPath = [System.IO.Path]::Combine($temporaryRoot, $artifactName)
    $signaturePath = $artifactPath + '.sig'
    $publicKeyPath = [System.IO.Path]::Combine($temporaryRoot, 'production.key.pub')
    $latestJsonPath = [System.IO.Path]::Combine($temporaryRoot, 'latest.json')
    $manifestPath = [System.IO.Path]::Combine($temporaryRoot, 'updater-release-manifest.json')
    $checksumPath = [System.IO.Path]::Combine($temporaryRoot, 'SHA256SUMS.txt')
    [System.IO.File]::WriteAllBytes($artifactPath, [byte[]](2,7,1,8,2,8,1,8,2,8,4,5,9))
    $signatureText = [Convert]::ToBase64String([byte[]](1..64))
    [System.IO.File]::WriteAllText($signaturePath, $signatureText, $utf8NoBom)
    [System.IO.File]::WriteAllText($publicKeyPath, [Convert]::ToBase64String([byte[]](65..112)), $utf8NoBom)

    $enabledConfigurationPath = [System.IO.Path]::Combine($temporaryRoot, 'hosting-enabled.json')
    $enabledConfigurationObject = $configurationText | ConvertFrom-Json
    $enabledConfigurationObject.enabled = $true
    $enabledConfigurationObject.metadata.ownerConfirmed = $true
    [System.IO.File]::WriteAllText($enabledConfigurationPath, ($enabledConfigurationObject | ConvertTo-Json -Depth 8), $utf8NoBom)
    $enabledConfiguration = Read-GitHubUpdaterHostingConfiguration -LiteralPath $enabledConfigurationPath
    $downloadUrl = Get-GitHubUpdaterAssetUrl -Configuration $enabledConfiguration -Version $version -AssetName $artifactName
    $downloadUri = New-Object Uri($downloadUrl)
    Test-Equal 'Release asset URL binds to a versioned tag' $true ([bool]($downloadUri.AbsolutePath -match '/releases/download/v0\.2\.1-beta\.1/'))
    Test-Equal 'Unicode Release asset URL round-trips exact filename' $artifactName ([Uri]::UnescapeDataString([System.IO.Path]::GetFileName($downloadUri.AbsolutePath)))
    Test-Equal 'Release tag preserves complete prerelease SemVer' "v$version" (Get-GitHubUpdaterReleaseTag -Configuration $enabledConfiguration -Version $version)
    Test-Equal 'Versioned metadata snapshot preserves complete SemVer' "https://github.com/ylc77/desktop-pet/releases/download/v$version/latest.json" (Get-GitHubUpdaterVersionedMetadataUrl -Configuration $enabledConfiguration -Version $version)

    $latest = New-UpdaterLatestDocument -Version $version -CurrentVersion $currentVersion -DownloadUrl $downloadUrl `
        -Signature $signatureText -Platform 'windows-x86_64' -PublishedAtUtc '2026-07-16T00:00:00Z' `
        -ArtifactSizeBytes (Get-Item -LiteralPath $artifactPath).Length
    Write-Utf8NoBomJson -InputObject $latest -LiteralPath $latestJsonPath
    $checksumLines = @(
        "$(Get-Sha256Hex -LiteralPath $artifactPath)  $artifactName",
        "$(Get-Sha256Hex -LiteralPath $signaturePath)  $([System.IO.Path]::GetFileName($signaturePath))",
        "$(Get-Sha256Hex -LiteralPath $latestJsonPath)  $([System.IO.Path]::GetFileName($latestJsonPath))"
    )
    [System.IO.File]::WriteAllLines($checksumPath, $checksumLines, $utf8NoBom)
    $commit = '0123456789abcdef0123456789abcdef01234567'
    $manifest = [ordered]@{
        schemaVersion=1
        applicationName=(-join @([char]0x4E03,[char]0x9171,[char]0x684C,[char]0x5BA0))
        version=$version
        currentVersion=$currentVersion
        identifier='dev.deskpet.framework'
        platform='windows-x86_64'
        artifactFile=$artifactName
        signatureFile=[System.IO.Path]::GetFileName($signaturePath)
        latestJsonFile=[System.IO.Path]::GetFileName($latestJsonPath)
        artifactSizeBytes=(Get-Item -LiteralPath $artifactPath).Length
        artifactSha256=Get-Sha256Hex -LiteralPath $artifactPath
        signatureSha256=Get-Sha256Hex -LiteralPath $signaturePath
        latestJsonSha256=Get-Sha256Hex -LiteralPath $latestJsonPath
        publicKeyFingerprint=Get-UpdaterPublicKeyFingerprint -LiteralPath $publicKeyPath
        downloadUrl=$downloadUrl
        endpoint=[string]$enabledConfiguration.metadata.endpoint
        installMode='passive'
        preparedAtUtc='2026-07-16T00:00:00Z'
        gitCommit=$commit
        dirtyWorktree=$false
        cryptographicSignatureVerified=$true
    }
    Write-Utf8NoBomJson -InputObject $manifest -LiteralPath $manifestPath
    $publicGitHubInvoker = {
        param([string]$FilePath, [string[]]$ArgumentList)
        if ($ArgumentList[0] -eq 'auth') { return [pscustomobject]@{ ExitCode=0; Output='' } }
        if ($ArgumentList[0] -eq 'repo') {
            return [pscustomobject]@{ ExitCode=0; Output='{"nameWithOwner":"ylc77/desktop-pet","isPrivate":false,"visibility":"PUBLIC","viewerPermission":"WRITE","url":"https://github.com/ylc77/desktop-pet"}' }
        }
        if ($ArgumentList[1] -eq 'user') { return [pscustomobject]@{ ExitCode=0; Output='ylc77' } }
        if ($ArgumentList[1] -match '/commits/') { return [pscustomobject]@{ ExitCode=0; Output='0123456789abcdef0123456789abcdef01234567' } }
        if ($ArgumentList[1] -match '/matching-refs/') { return [pscustomobject]@{ ExitCode=0; Output='[]' } }
        if ($ArgumentList[1] -match '/releases\?') { return [pscustomobject]@{ ExitCode=0; Output='[[]]' } }
        return [pscustomobject]@{ ExitCode=1; Output='' }
    }
    $plannedAssetNames = @($artifactName,[System.IO.Path]::GetFileName($signaturePath),[System.IO.Path]::GetFileName($latestJsonPath),[System.IO.Path]::GetFileName($manifestPath),[System.IO.Path]::GetFileName($checksumPath))
    $githubState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
        -AssetNames $plannedAssetNames -ReleaseExpectation Absent -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $publicGitHubInvoker
    Test-Equal 'Read-only GitHub state accepts authenticated public exact repository' $true ([bool]($githubState.Authenticated -and $githubState.RepositoryMatches -and $githubState.PublicRepository -and $githubState.PermissionSufficient -and $githubState.HeadCommitExists))
    Test-Equal 'Operator public login is redacted in the release state' 'yl***' ([string]$githubState.OperatorLogin)
    Test-Equal 'Unused target tag, release, and asset names satisfy preflight' $true ([bool]($githubState.TargetTagStateSatisfied -and $githubState.TargetReleaseStateSatisfied -and $githubState.AssetNameStateSatisfied))
    $priorMetadataInvoker = {
        param([string]$FilePath, [string[]]$ArgumentList)
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/releases\?') {
            $reusedMetadata = @(
                [System.IO.Path]::GetFileName($latestJsonPath),
                [System.IO.Path]::GetFileName($manifestPath),
                [System.IO.Path]::GetFileName($checksumPath)
            ) | ForEach-Object { [ordered]@{ name=$_ } }
            $releaseJson = @([ordered]@{ tag_name='v0.2.0-beta.1'; assets=@($reusedMetadata) }) | ConvertTo-Json -Depth 6 -Compress
            return [pscustomobject]@{ ExitCode=0; Output=('[' + $releaseJson + ']') }
        }
        return & $publicGitHubInvoker $FilePath $ArgumentList
    }.GetNewClosure()
    $priorMetadataState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
        -AssetNames $plannedAssetNames -GloballyUniqueAssetNames @($artifactName,[System.IO.Path]::GetFileName($signaturePath)) `
        -ReleaseExpectation Absent -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $priorMetadataInvoker
    Test-Equal 'Metadata filenames may be reused by a newer versioned Release' $true ([bool]$priorMetadataState.AssetNameStateSatisfied)
    $capturedCommands = New-Object System.Collections.ArrayList
    $capturingInvoker = {
        param([string]$FilePath, [string[]]$ArgumentList)
        [void]$capturedCommands.Add([string[]]$ArgumentList.Clone())
        return & $publicGitHubInvoker $FilePath $ArgumentList
    }.GetNewClosure()
    $savedGhHost = $env:GH_HOST
    try {
        $env:GH_HOST = 'evil.invalid'
        [void](Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
            -AssetNames $plannedAssetNames -ReleaseExpectation Absent -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $capturingInvoker)
        $allApiCommandsPinned = $true
        foreach ($capturedCommand in @($capturedCommands | Where-Object { $_[0] -eq 'api' })) {
            $hostnameIndex = [Array]::IndexOf([string[]]$capturedCommand, '--hostname')
            if ($hostnameIndex -lt 0 -or $hostnameIndex + 1 -ge $capturedCommand.Count -or $capturedCommand[$hostnameIndex + 1] -cne 'github.com') {
                $allApiCommandsPinned = $false
            }
        }
        Test-Equal 'Every gh api command pins github.com despite malicious GH_HOST' $true $allApiCommandsPinned
        $capturedRepoCommand = @($capturedCommands | Where-Object { $_[0] -eq 'repo' })[0]
        Test-Equal 'gh repo view uses a host-qualified repository' 'github.com/ylc77/desktop-pet' ([string]$capturedRepoCommand[2])
        $downloadArguments = Get-GitHubUpdaterReleaseDownloadArguments -Repository 'ylc77/desktop-pet' -Tag "v$version" `
            -AssetNames $plannedAssetNames -DestinationDirectory $temporaryRoot
        $downloadRepositoryIndex = [Array]::IndexOf([string[]]$downloadArguments, '--repo')
        Test-Equal 'gh release download uses a host-qualified repository' 'github.com/ylc77/desktop-pet' `
            ([string]$downloadArguments[$downloadRepositoryIndex + 1])
    } finally {
        if ($null -eq $savedGhHost) { Remove-Item Env:GH_HOST -ErrorAction SilentlyContinue } else { $env:GH_HOST = $savedGhHost }
    }
    $failedAuthInvoker = { param([string]$FilePath, [string[]]$ArgumentList); [pscustomobject]@{ ExitCode=1; Output='' } }
    $failedAuthState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
        -AssetNames $plannedAssetNames -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $failedAuthInvoker
    Test-Equal 'Missing GitHub authentication fails repository readiness' $false ([bool]$failedAuthState.Authenticated)
    $readOnlyInvoker = {
        param([string]$FilePath, [string[]]$ArgumentList)
        if ($ArgumentList[0] -eq 'repo') {
            return [pscustomobject]@{ ExitCode=0; Output='{"nameWithOwner":"ylc77/desktop-pet","isPrivate":false,"visibility":"PUBLIC","viewerPermission":"READ","url":"https://github.com/ylc77/desktop-pet"}' }
        }
        return & $publicGitHubInvoker $FilePath $ArgumentList
    }.GetNewClosure()
    $readOnlyState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
        -AssetNames $plannedAssetNames -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $readOnlyInvoker
    Test-Equal 'GitHub READ permission is insufficient for release planning' $false ([bool]$readOnlyState.PermissionSufficient)
    $failedReleaseQueryInvoker = {
        param([string]$FilePath, [string[]]$ArgumentList)
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/releases\?') {
            return [pscustomobject]@{ ExitCode=1; Output='' }
        }
        return & $publicGitHubInvoker $FilePath $ArgumentList
    }.GetNewClosure()
    $failedQueryState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
        -AssetNames $plannedAssetNames -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $failedReleaseQueryInvoker
    Test-Equal 'GitHub release query errors fail closed' $false ([bool]$failedQueryState.QueriesSucceeded)
    foreach ($malformedJson in @('null','{}','"unexpected"','7')) {
        $malformedTagInvoker = {
            param([string]$FilePath, [string[]]$ArgumentList)
            if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/matching-refs/') {
                return [pscustomobject]@{ ExitCode=0; Output=$malformedJson }
            }
            return & $publicGitHubInvoker $FilePath $ArgumentList
        }.GetNewClosure()
        $malformedTagState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
            -AssetNames $plannedAssetNames -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $malformedTagInvoker
        Test-Equal "Malformed tag JSON fails closed: $malformedJson" $false ([bool]$malformedTagState.QueriesSucceeded)

        $malformedReleaseInvoker = {
            param([string]$FilePath, [string[]]$ArgumentList)
            if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/releases\?') {
                return [pscustomobject]@{ ExitCode=0; Output=$malformedJson }
            }
            return & $publicGitHubInvoker $FilePath $ArgumentList
        }.GetNewClosure()
        $malformedReleaseState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
            -AssetNames $plannedAssetNames -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $malformedReleaseInvoker
        Test-Equal "Malformed release JSON fails closed: $malformedJson" $false ([bool]$malformedReleaseState.QueriesSucceeded)
    }
    $missingCommitInvoker = {
        param([string]$FilePath, [string[]]$ArgumentList)
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/commits/') {
            return [pscustomobject]@{ ExitCode=1; Output='' }
        }
        return & $publicGitHubInvoker $FilePath $ArgumentList
    }.GetNewClosure()
    $missingCommitState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
        -AssetNames $plannedAssetNames -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $missingCommitInvoker
    Test-Equal 'HEAD missing from the target GitHub repository fails closed' $false ([bool]$missingCommitState.HeadCommitExists)
    $stringPrivateInvoker = {
        param([string]$FilePath, [string[]]$ArgumentList)
        if ($ArgumentList[0] -eq 'repo') {
            return [pscustomobject]@{ ExitCode=0; Output='{"nameWithOwner":"ylc77/desktop-pet","isPrivate":"false","visibility":"PUBLIC","viewerPermission":"WRITE"}' }
        }
        return & $publicGitHubInvoker $FilePath $ArgumentList
    }.GetNewClosure()
    $stringPrivateState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
        -AssetNames $plannedAssetNames -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $stringPrivateInvoker
    Test-Equal 'String false cannot make a repository public' $false ([bool]$stringPrivateState.QueriesSucceeded)
    $collisionInvoker = {
        param([string]$FilePath, [string[]]$ArgumentList)
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/matching-refs/') {
            return [pscustomobject]@{ ExitCode=0; Output='[{"ref":"refs/tags/v0.2.1-beta.1"}]' }
        }
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/releases\?') {
            $releaseJson = @([ordered]@{ tag_name='v0.2.1-beta.1'; assets=@([ordered]@{ name=$artifactName }) }) | ConvertTo-Json -Depth 6 -Compress
            return [pscustomobject]@{ ExitCode=0; Output=('[' + $releaseJson + ']') }
        }
        return & $publicGitHubInvoker $FilePath $ArgumentList
    }.GetNewClosure()
    $collisionState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
        -AssetNames $plannedAssetNames -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $collisionInvoker
    Test-Equal 'Existing tag, release, or versioned asset collision closes preflight' $false `
        ([bool]($collisionState.TargetTagStateSatisfied -and $collisionState.TargetReleaseStateSatisfied -and $collisionState.AssetNameStateSatisfied))
    $presentReleaseInvoker = {
        param([string]$FilePath, [string[]]$ArgumentList)
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/matching-refs/') {
            return [pscustomobject]@{ ExitCode=0; Output=("[{'ref':'refs/tags/v0.2.1-beta.1','object':{'type':'commit','sha':'$commit'}}]".Replace("'",'"')) }
        }
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/releases\?') {
            $assets = @($plannedAssetNames | ForEach-Object { [ordered]@{ name=$_ } })
            $releaseJson = @([ordered]@{ tag_name='v0.2.1-beta.1'; target_commitish=$commit; draft=$false; prerelease=$true; assets=$assets }) | ConvertTo-Json -Depth 6 -Compress
            return [pscustomobject]@{ ExitCode=0; Output=('[' + $releaseJson + ']') }
        }
        return & $publicGitHubInvoker $FilePath $ArgumentList
    }.GetNewClosure()
    $presentReleaseState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
        -AssetNames $plannedAssetNames -ReleaseExpectation Present -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $presentReleaseInvoker
    Test-Equal 'Remote verification requires one exact tag, release, and complete asset set' $true `
        ([bool]($presentReleaseState.TargetTagStateSatisfied -and $presentReleaseState.TargetReleaseStateSatisfied -and $presentReleaseState.AssetNameStateSatisfied))
    $draftReleaseInvoker = {
        param([string]$FilePath, [string[]]$ArgumentList)
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/matching-refs/') {
            return [pscustomobject]@{ ExitCode=0; Output='[]' }
        }
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/releases\?') {
            $assets = @($plannedAssetNames | ForEach-Object { [ordered]@{ name=$_ } })
            $releaseJson = @([ordered]@{ tag_name='v0.2.1-beta.1'; target_commitish=$commit; draft=$true; prerelease=$true; assets=$assets }) | ConvertTo-Json -Depth 6 -Compress
            return [pscustomobject]@{ ExitCode=0; Output=('[' + $releaseJson + ']') }
        }
        return & $publicGitHubInvoker $FilePath $ArgumentList
    }.GetNewClosure()
    $draftReleaseState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
        -AssetNames $plannedAssetNames -ReleaseExpectation Draft -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $draftReleaseInvoker
    Test-Equal 'Draft verification accepts an exact draft release before Git creates the tag ref' $true `
        ([bool]($draftReleaseState.TargetTagStateSatisfied -and $draftReleaseState.TargetReleaseStateSatisfied -and $draftReleaseState.AssetNameStateSatisfied))
    $missingReleaseShapeInvoker = {
        param([string]$FilePath, [string[]]$ArgumentList)
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/matching-refs/') {
            return [pscustomobject]@{ ExitCode=0; Output='[]' }
        }
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/releases\?') {
            $assets = @($plannedAssetNames | ForEach-Object { [ordered]@{ name=$_ } })
            $releaseJson = @([ordered]@{ tag_name='v0.2.1-beta.1'; assets=$assets }) | ConvertTo-Json -Depth 6 -Compress
            return [pscustomobject]@{ ExitCode=0; Output=('[' + $releaseJson + ']') }
        }
        return & $publicGitHubInvoker $FilePath $ArgumentList
    }.GetNewClosure()
    $missingReleaseShapeState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
        -AssetNames $plannedAssetNames -ReleaseExpectation Draft -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $missingReleaseShapeInvoker
    Test-Equal 'Release fields missing from the API response fail closed' $false ([bool]$missingReleaseShapeState.TargetReleaseStateSatisfied)

    $wrongTagInvoker = {
        param([string]$FilePath, [string[]]$ArgumentList)
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/matching-refs/') {
            return [pscustomobject]@{ ExitCode=0; Output='[{"ref":"refs/tags/v0.2.1-beta.1","object":{"type":"commit","sha":"ffffffffffffffffffffffffffffffffffffffff"}}]' }
        }
        return & $presentReleaseInvoker $FilePath $ArgumentList
    }.GetNewClosure()
    $wrongTagState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
        -AssetNames $plannedAssetNames -ReleaseExpectation Present -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $wrongTagInvoker
    Test-Equal 'A tag pointing at another commit fails closed' $false ([bool]$wrongTagState.TargetTagStateSatisfied)

    $wrongTargetInvoker = {
        param([string]$FilePath, [string[]]$ArgumentList)
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/matching-refs/') {
            return [pscustomobject]@{ ExitCode=0; Output='[]' }
        }
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/releases\?') {
            $assets = @($plannedAssetNames | ForEach-Object { [ordered]@{ name=$_ } })
            $releaseJson = @([ordered]@{ tag_name='v0.2.1-beta.1'; target_commitish=('f' * 40); draft=$true; prerelease=$true; assets=$assets }) | ConvertTo-Json -Depth 6 -Compress
            return [pscustomobject]@{ ExitCode=0; Output=('[' + $releaseJson + ']') }
        }
        return & $publicGitHubInvoker $FilePath $ArgumentList
    }.GetNewClosure()
    $wrongTargetState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
        -AssetNames $plannedAssetNames -ReleaseExpectation Draft -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $wrongTargetInvoker
    Test-Equal 'A release targeting another commit fails closed' $false ([bool]$wrongTargetState.TargetReleaseStateSatisfied)

    $branchTargetInvoker = {
        param([string]$FilePath, [string[]]$ArgumentList)
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/matching-refs/') {
            return [pscustomobject]@{ ExitCode=0; Output='[]' }
        }
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/releases\?') {
            $assets = @($plannedAssetNames | ForEach-Object { [ordered]@{ name=$_ } })
            $releaseJson = @([ordered]@{ tag_name='v0.2.1-beta.1'; target_commitish='main'; draft=$true; prerelease=$true; assets=$assets }) | ConvertTo-Json -Depth 6 -Compress
            return [pscustomobject]@{ ExitCode=0; Output=('[' + $releaseJson + ']') }
        }
        return & $publicGitHubInvoker $FilePath $ArgumentList
    }.GetNewClosure()
    $branchTargetState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
        -AssetNames $plannedAssetNames -ReleaseExpectation Draft -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $branchTargetInvoker
    Test-Equal 'A release branch target must resolve to the exact manifest commit' $true ([bool]$branchTargetState.TargetReleaseStateSatisfied)
    $branchResolutionCommands = New-Object System.Collections.ArrayList
    $capturingBranchInvoker = {
        param([string]$FilePath, [string[]]$ArgumentList)
        [void]$branchResolutionCommands.Add([string[]]$ArgumentList.Clone())
        return & $branchTargetInvoker $FilePath $ArgumentList
    }.GetNewClosure()
    $savedBranchGhHost = $env:GH_HOST
    try {
        $env:GH_HOST = 'evil.invalid'
        [void](Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
            -AssetNames $plannedAssetNames -ReleaseExpectation Draft -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $capturingBranchInvoker)
        $branchResolutionApi = @($branchResolutionCommands | Where-Object { $_[0] -eq 'api' -and $_[1] -match '/commits/main$' })[0]
        $branchHostnameIndex = [Array]::IndexOf([string[]]$branchResolutionApi, '--hostname')
        Test-Equal 'Branch target resolution also pins github.com' 'github.com' ([string]$branchResolutionApi[$branchHostnameIndex + 1])
    } finally {
        if ($null -eq $savedBranchGhHost) { Remove-Item Env:GH_HOST -ErrorAction SilentlyContinue } else { $env:GH_HOST = $savedBranchGhHost }
    }

    $publishedDraftInvoker = {
        param([string]$FilePath, [string[]]$ArgumentList)
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/matching-refs/') {
            return [pscustomobject]@{ ExitCode=0; Output='[]' }
        }
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/releases\?') {
            $assets = @($plannedAssetNames | ForEach-Object { [ordered]@{ name=$_ } })
            $releaseJson = @([ordered]@{ tag_name='v0.2.1-beta.1'; target_commitish=$commit; draft=$false; prerelease=$true; assets=$assets }) | ConvertTo-Json -Depth 6 -Compress
            return [pscustomobject]@{ ExitCode=0; Output=('[' + $releaseJson + ']') }
        }
        return & $publicGitHubInvoker $FilePath $ArgumentList
    }.GetNewClosure()
    $publishedDraftState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
        -AssetNames $plannedAssetNames -ReleaseExpectation Draft -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $publishedDraftInvoker
    Test-Equal 'A published release cannot satisfy draft verification' $false ([bool]$publishedDraftState.TargetReleaseStateSatisfied)

    $stableReleaseInvoker = {
        param([string]$FilePath, [string[]]$ArgumentList)
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/matching-refs/') {
            return [pscustomobject]@{ ExitCode=0; Output='[]' }
        }
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/releases\?') {
            $assets = @($plannedAssetNames | ForEach-Object { [ordered]@{ name=$_ } })
            $releaseJson = @([ordered]@{ tag_name='v0.2.1-beta.1'; target_commitish=$commit; draft=$true; prerelease=$false; assets=$assets }) | ConvertTo-Json -Depth 6 -Compress
            return [pscustomobject]@{ ExitCode=0; Output=('[' + $releaseJson + ']') }
        }
        return & $publicGitHubInvoker $FilePath $ArgumentList
    }.GetNewClosure()
    $stableReleaseState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
        -AssetNames $plannedAssetNames -ReleaseExpectation Draft -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $stableReleaseInvoker
    Test-Equal 'A non-prerelease release is rejected when prerelease is expected' $false ([bool]$stableReleaseState.TargetReleaseStateSatisfied)
    $latestBetaReleaseState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
        -AssetNames $plannedAssetNames -ReleaseExpectation Draft -ExpectedPrerelease $false -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $stableReleaseInvoker
    Test-Equal 'A draft non-prerelease release satisfies the releases/latest beta contract' $true ([bool]$latestBetaReleaseState.TargetReleaseStateSatisfied)

    $extraAssetInvoker = {
        param([string]$FilePath, [string[]]$ArgumentList)
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/matching-refs/') {
            return [pscustomobject]@{ ExitCode=0; Output='[]' }
        }
        if ($ArgumentList[0] -eq 'api' -and $ArgumentList[1] -match '/releases\?') {
            $assets = @($plannedAssetNames | ForEach-Object { [ordered]@{ name=$_ } }) + @([ordered]@{ name='unexpected.exe' })
            $releaseJson = @([ordered]@{ tag_name='v0.2.1-beta.1'; target_commitish=$commit; draft=$true; prerelease=$true; assets=$assets }) | ConvertTo-Json -Depth 6 -Compress
            return [pscustomobject]@{ ExitCode=0; Output=('[' + $releaseJson + ']') }
        }
        return & $publicGitHubInvoker $FilePath $ArgumentList
    }.GetNewClosure()
    $extraAssetState = Get-GitHubUpdaterRepositoryState -Repository 'ylc77/desktop-pet' -HeadCommit $commit -Tag "v$version" `
        -AssetNames $plannedAssetNames -ReleaseExpectation Draft -GitHubCliPath 'fixture-gh.exe' -CommandInvoker $extraAssetInvoker
    Test-Equal 'An extra Release asset invalidates the exact asset set' $false ([bool]$extraAssetState.AssetNameStateSatisfied)

    $matchingOriginState = Get-GitHubUpdaterLocalGitState -RepositoryRoot $repositoryRoot -ExpectedRepository 'ylc77/desktop-pet' `
        -GitInvoker { param($Root); [pscustomobject]@{ ExitCode=0; Output='git@github.com:ylc77/desktop-pet.git' } }
    Test-Equal 'Local SSH origin binds to the configured repository' $true ([bool]$matchingOriginState.OriginMatches)
    $wrongOriginState = Get-GitHubUpdaterLocalGitState -RepositoryRoot $repositoryRoot -ExpectedRepository 'ylc77/desktop-pet' `
        -GitInvoker { param($Root); [pscustomobject]@{ ExitCode=0; Output='https://github.com/someone/other.git' } }
    Test-Equal 'Mismatched local origin closes repository binding' $false ([bool]$wrongOriginState.OriginMatches)

    $gitState = [pscustomobject]@{ Commit=$commit; DirtyWorktree=$false; OriginMatches=$true; OriginRepository='ylc77/desktop-pet' }
    $signatureVerifier = { param($Artifact,$Signature,$PublicKey); return $true }
    $plan = New-GitHubUpdaterReleasePlan -Configuration $enabledConfiguration -Version $version -CurrentVersion $currentVersion `
        -ArtifactPath $artifactPath -SignaturePath $signaturePath -PublicKeyPath $publicKeyPath `
        -LatestJsonPath $latestJsonPath -ManifestPath $manifestPath -ChecksumPath $checksumPath -GitState $gitState -GitHubState $githubState `
        -SignatureVerifier $signatureVerifier
    Test-Equal 'Complete local GitHub release preflight opens its gate' $true ([bool]$plan.GateSatisfied)
    Test-Equal 'Release plan is draft-first' $true ([bool]$plan.Release.Draft)
    Test-Equal 'Release plan leaves GitHub prerelease false for releases/latest routing' $false ([bool]$plan.Release.Prerelease)
    Test-Equal 'Release plan never performs a remote mutation' $false ([bool]$plan.RemoteMutationPerformed)
    Test-Equal 'Metadata plan publishes only after remote verification' $true ([bool]($plan.Metadata.PublishOrder -match 'verify|verified'))
    Test-Equal 'Remote plan requires anonymous verification after publish' $true ([bool]$plan.RemoteVerification.RequireAnonymousDownloadAfterPublish)
    $bundle = Assert-GitHubUpdaterReleaseBundle -Configuration $enabledConfiguration -Version $version -CurrentVersion $currentVersion `
        -ArtifactPath $artifactPath -SignaturePath $signaturePath -PublicKeyPath $publicKeyPath -LatestJsonPath $latestJsonPath `
        -ManifestPath $manifestPath -ChecksumPath $checksumPath -SignatureVerifier $signatureVerifier
    Test-Equal 'Independent release bundle validation accepts exact fixture' $true ([bool]$bundle.Valid)

    $validManifestText = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
    $invalidPlanManifestCases = @(
        @{ Name='schemaVersion'; Apply={ param($value); $value.schemaVersion = '1' } },
        @{ Name='identifier'; Apply={ param($value); $value.identifier = 'invalid.application' } },
        @{ Name='platform'; Apply={ param($value); $value.platform = 'windows-aarch64' } },
        @{ Name='installMode'; Apply={ param($value); $value.installMode = 'basicUi' } },
        @{ Name='latestJsonFile'; Apply={ param($value); $value.latestJsonFile = 'other.json' } }
    )
    foreach ($invalidPlanManifestCase in $invalidPlanManifestCases) {
        $invalidPlanManifest = $validManifestText | ConvertFrom-Json
        & $invalidPlanManifestCase.Apply $invalidPlanManifest
        [System.IO.File]::WriteAllText($manifestPath, ($invalidPlanManifest | ConvertTo-Json -Depth 8), $utf8NoBom)
        try {
            $invalidManifestPlan = New-GitHubUpdaterReleasePlan -Configuration $enabledConfiguration -Version $version -CurrentVersion $currentVersion `
                -ArtifactPath $artifactPath -SignaturePath $signaturePath -PublicKeyPath $publicKeyPath `
                -LatestJsonPath $latestJsonPath -ManifestPath $manifestPath -ChecksumPath $checksumPath -GitState $gitState -GitHubState $githubState `
                -SignatureVerifier $signatureVerifier
            Test-Equal ("Invalid manifest " + [string]$invalidPlanManifestCase.Name + ' closes the publication Gate') $false ([bool]$invalidManifestPlan.GateSatisfied)
        } catch {
            Add-Test ("Invalid manifest " + [string]$invalidPlanManifestCase.Name + ' closes the publication Gate') $false $_.Exception.Message
        }
    }
    [System.IO.File]::WriteAllText($manifestPath, $validManifestText, $utf8NoBom)
    $invalidBooleanManifest = $validManifestText | ConvertFrom-Json
    $invalidBooleanManifest.dirtyWorktree = 'false'
    [System.IO.File]::WriteAllText($manifestPath, ($invalidBooleanManifest | ConvertTo-Json -Depth 8), $utf8NoBom)
    Test-Throws 'Remote manifest string false cannot bypass dirty-state validation' {
        Assert-GitHubUpdaterReleaseBundle -Configuration $enabledConfiguration -Version $version -CurrentVersion $currentVersion `
            -ArtifactPath $artifactPath -SignaturePath $signaturePath -PublicKeyPath $publicKeyPath -LatestJsonPath $latestJsonPath `
            -ManifestPath $manifestPath -ChecksumPath $checksumPath -SignatureVerifier $signatureVerifier
    } 'JSON Boolean'
    [System.IO.File]::WriteAllText($manifestPath, $validManifestText, $utf8NoBom)

    $invalidSchemaManifest = $validManifestText | ConvertFrom-Json
    $invalidSchemaManifest.schemaVersion = '1'
    [System.IO.File]::WriteAllText($manifestPath, ($invalidSchemaManifest | ConvertTo-Json -Depth 8), $utf8NoBom)
    Test-Throws 'Remote manifest string schemaVersion is rejected' {
        Assert-GitHubUpdaterReleaseBundle -Configuration $enabledConfiguration -Version $version -CurrentVersion $currentVersion `
            -ArtifactPath $artifactPath -SignaturePath $signaturePath -PublicKeyPath $publicKeyPath -LatestJsonPath $latestJsonPath `
            -ManifestPath $manifestPath -ChecksumPath $checksumPath -SignatureVerifier $signatureVerifier
    } 'integer 1'
    [System.IO.File]::WriteAllText($manifestPath, $validManifestText, $utf8NoBom)

    $unknownManifest = $validManifestText | ConvertFrom-Json
    $unknownManifest | Add-Member -NotePropertyName 'debugMetadata' -NotePropertyValue 'not-reviewed'
    [System.IO.File]::WriteAllText($manifestPath, ($unknownManifest | ConvertTo-Json -Depth 8), $utf8NoBom)
    Test-Throws 'Remote manifest rejects unknown top-level fields' {
        Assert-GitHubUpdaterReleaseBundle -Configuration $enabledConfiguration -Version $version -CurrentVersion $currentVersion `
            -ArtifactPath $artifactPath -SignaturePath $signaturePath -PublicKeyPath $publicKeyPath -LatestJsonPath $latestJsonPath `
            -ManifestPath $manifestPath -ChecksumPath $checksumPath -SignatureVerifier $signatureVerifier
    } 'exactly|unknown'
    [System.IO.File]::WriteAllText($manifestPath, $validManifestText, $utf8NoBom)

    foreach ($sensitiveFieldName in @('credential','refreshToken')) {
        $sensitiveManifest = $validManifestText | ConvertFrom-Json
        $sensitiveManifest | Add-Member -NotePropertyName $sensitiveFieldName -NotePropertyValue 'must-not-pass'
        [System.IO.File]::WriteAllText($manifestPath, ($sensitiveManifest | ConvertTo-Json -Depth 8), $utf8NoBom)
        $sensitiveManifestAction = {
            Assert-GitHubUpdaterReleaseBundle -Configuration $enabledConfiguration -Version $version -CurrentVersion $currentVersion `
                -ArtifactPath $artifactPath -SignaturePath $signaturePath -PublicKeyPath $publicKeyPath -LatestJsonPath $latestJsonPath `
                -ManifestPath $manifestPath -ChecksumPath $checksumPath -SignatureVerifier $signatureVerifier
        }.GetNewClosure()
        Test-Throws "Remote manifest rejects sensitive field $sensitiveFieldName" $sensitiveManifestAction 'sensitive|secret'
    }
    [System.IO.File]::WriteAllText($manifestPath, $validManifestText, $utf8NoBom)

    $invalidTransitionManifest = $validManifestText | ConvertFrom-Json
    $invalidTransitionManifest.currentVersion = '0.1.0'
    [System.IO.File]::WriteAllText($manifestPath, ($invalidTransitionManifest | ConvertTo-Json -Depth 8), $utf8NoBom)
    Test-Throws 'Remote manifest currentVersion must match the planned transition' {
        Assert-GitHubUpdaterReleaseBundle -Configuration $enabledConfiguration -Version $version -CurrentVersion $currentVersion `
            -ArtifactPath $artifactPath -SignaturePath $signaturePath -PublicKeyPath $publicKeyPath -LatestJsonPath $latestJsonPath `
            -ManifestPath $manifestPath -ChecksumPath $checksumPath -SignatureVerifier $signatureVerifier
    } 'version transition'
    [System.IO.File]::WriteAllText($manifestPath, $validManifestText, $utf8NoBom)

    $invalidCommitManifest = $validManifestText | ConvertFrom-Json
    $invalidCommitManifest.gitCommit = 'not-a-commit'
    [System.IO.File]::WriteAllText($manifestPath, ($invalidCommitManifest | ConvertTo-Json -Depth 8), $utf8NoBom)
    Test-Throws 'Remote manifest must contain a valid target-repository commit' {
        Assert-GitHubUpdaterReleaseBundle -Configuration $enabledConfiguration -Version $version -CurrentVersion $currentVersion `
            -ArtifactPath $artifactPath -SignaturePath $signaturePath -PublicKeyPath $publicKeyPath -LatestJsonPath $latestJsonPath `
            -ManifestPath $manifestPath -ChecksumPath $checksumPath -SignatureVerifier $signatureVerifier
    } 'valid Git commit'
    [System.IO.File]::WriteAllText($manifestPath, $validManifestText, $utf8NoBom)

    $invalidFingerprintManifest = $validManifestText | ConvertFrom-Json
    $invalidFingerprintManifest.publicKeyFingerprint = ('0' * 64 -join '')
    [System.IO.File]::WriteAllText($manifestPath, ($invalidFingerprintManifest | ConvertTo-Json -Depth 8), $utf8NoBom)
    Test-Throws 'Remote manifest public-key fingerprint mismatch is rejected' {
        Assert-GitHubUpdaterReleaseBundle -Configuration $enabledConfiguration -Version $version -CurrentVersion $currentVersion `
            -ArtifactPath $artifactPath -SignaturePath $signaturePath -PublicKeyPath $publicKeyPath -LatestJsonPath $latestJsonPath `
            -ManifestPath $manifestPath -ChecksumPath $checksumPath -SignatureVerifier $signatureVerifier
    } 'public key'
    [System.IO.File]::WriteAllText($manifestPath, $validManifestText, $utf8NoBom)

    $invalidSizeManifest = $validManifestText | ConvertFrom-Json
    $invalidSizeManifest.artifactSizeBytes = [long]$invalidSizeManifest.artifactSizeBytes + 1
    [System.IO.File]::WriteAllText($manifestPath, ($invalidSizeManifest | ConvertTo-Json -Depth 8), $utf8NoBom)
    Test-Throws 'Remote manifest artifact size mismatch is rejected' {
        Assert-GitHubUpdaterReleaseBundle -Configuration $enabledConfiguration -Version $version -CurrentVersion $currentVersion `
            -ArtifactPath $artifactPath -SignaturePath $signaturePath -PublicKeyPath $publicKeyPath -LatestJsonPath $latestJsonPath `
            -ManifestPath $manifestPath -ChecksumPath $checksumPath -SignatureVerifier $signatureVerifier
    } 'size or SHA-256'
    [System.IO.File]::WriteAllText($manifestPath, $validManifestText, $utf8NoBom)

    $validLatestText = Get-Content -LiteralPath $latestJsonPath -Raw -Encoding UTF8
    $validChecksumText = Get-Content -LiteralPath $checksumPath -Raw -Encoding UTF8
    $aliasedLatest = $validLatestText | ConvertFrom-Json
    $aliasedLatest.platforms.'windows-x86_64'.url = 'https://github.com/ylc77/desktop-pet/releases/download/v0.2.1-beta.1/alias.exe'
    [System.IO.File]::WriteAllText($latestJsonPath, ($aliasedLatest | ConvertTo-Json -Depth 8), $utf8NoBom)
    $aliasedLatestHash = Get-Sha256Hex -LiteralPath $latestJsonPath
    $aliasedManifest = $validManifestText | ConvertFrom-Json
    $aliasedManifest.latestJsonSha256 = $aliasedLatestHash
    [System.IO.File]::WriteAllText($manifestPath, ($aliasedManifest | ConvertTo-Json -Depth 8), $utf8NoBom)
    $aliasedChecksums = @(
        "$(Get-Sha256Hex -LiteralPath $artifactPath)  $artifactName",
        "$(Get-Sha256Hex -LiteralPath $signaturePath)  $([System.IO.Path]::GetFileName($signaturePath))",
        "$aliasedLatestHash  $([System.IO.Path]::GetFileName($latestJsonPath))"
    )
    [System.IO.File]::WriteAllLines($checksumPath, $aliasedChecksums, $utf8NoBom)
    Test-Throws 'Remote latest.json asset URL alias is rejected independently' {
        Assert-GitHubUpdaterReleaseBundle -Configuration $enabledConfiguration -Version $version -CurrentVersion $currentVersion `
            -ArtifactPath $artifactPath -SignaturePath $signaturePath -PublicKeyPath $publicKeyPath -LatestJsonPath $latestJsonPath `
            -ManifestPath $manifestPath -ChecksumPath $checksumPath -SignatureVerifier $signatureVerifier
    } 'exactly match|does not bind'
    [System.IO.File]::WriteAllText($latestJsonPath, $validLatestText, $utf8NoBom)
    [System.IO.File]::WriteAllText($manifestPath, $validManifestText, $utf8NoBom)
    [System.IO.File]::WriteAllText($checksumPath, $validChecksumText, $utf8NoBom)

    $corruptedChecksumText = $(if ($validChecksumText[0] -eq 'A') { 'B' } else { 'A' }) + $validChecksumText.Substring(1)
    [System.IO.File]::WriteAllText($checksumPath, $corruptedChecksumText, $utf8NoBom)
    $checksumMismatchPlan = New-GitHubUpdaterReleasePlan -Configuration $enabledConfiguration -Version $version -CurrentVersion $currentVersion `
        -ArtifactPath $artifactPath -SignaturePath $signaturePath -PublicKeyPath $publicKeyPath `
        -LatestJsonPath $latestJsonPath -ManifestPath $manifestPath -ChecksumPath $checksumPath -GitState $gitState -GitHubState $githubState `
        -SignatureVerifier $signatureVerifier
    Test-Equal 'Checksum mismatch keeps the release preflight gate closed' $false ([bool]$checksumMismatchPlan.GateSatisfied)
    [System.IO.File]::WriteAllText($checksumPath, $validChecksumText, $utf8NoBom)

    $disabledConfiguration = $configurationText | ConvertFrom-Json
    $disabledConfiguration.enabled = $false
    $disabledPlan = New-GitHubUpdaterReleasePlan -Configuration $disabledConfiguration -Version $version -CurrentVersion $currentVersion `
        -ArtifactPath $artifactPath -SignaturePath $signaturePath -PublicKeyPath $publicKeyPath `
        -LatestJsonPath $latestJsonPath -ManifestPath $manifestPath -ChecksumPath $checksumPath -GitState $gitState -GitHubState $githubState `
        -SignatureVerifier $signatureVerifier
    Test-Equal 'Disabled formal hosting configuration keeps the gate closed' $false ([bool]$disabledPlan.GateSatisfied)
    $dirtyPlan = New-GitHubUpdaterReleasePlan -Configuration $enabledConfiguration -Version $version -CurrentVersion $currentVersion `
        -ArtifactPath $artifactPath -SignaturePath $signaturePath -PublicKeyPath $publicKeyPath `
        -LatestJsonPath $latestJsonPath -ManifestPath $manifestPath -ChecksumPath $checksumPath -GitState ([pscustomobject]@{ Commit=$commit; DirtyWorktree=$true }) `
        -GitHubState $githubState -SignatureVerifier $signatureVerifier
    Test-Equal 'Dirty worktree keeps the release preflight gate closed' $false ([bool]$dirtyPlan.GateSatisfied)
    $privateState = [pscustomobject]@{
        CliAvailable=$true; Authenticated=$true; QueriesSucceeded=$true; RepositoryMatches=$true; PublicRepository=$false
        PermissionSufficient=$true; HeadCommitExists=$true; TargetTagStateSatisfied=$true; TargetReleaseStateSatisfied=$true
        AssetNameStateSatisfied=$true; OperatorLogin='yl***'
    }
    $privatePlan = New-GitHubUpdaterReleasePlan -Configuration $enabledConfiguration -Version $version -CurrentVersion $currentVersion `
        -ArtifactPath $artifactPath -SignaturePath $signaturePath -PublicKeyPath $publicKeyPath `
        -LatestJsonPath $latestJsonPath -ManifestPath $manifestPath -ChecksumPath $checksumPath -GitState $gitState -GitHubState $privateState `
        -SignatureVerifier $signatureVerifier
    Test-Equal 'Private repository keeps anonymous updater release gate closed' $false ([bool]$privatePlan.GateSatisfied)

    $badConfigurationPath = [System.IO.Path]::Combine($temporaryRoot, 'bad-hosting.json')
    $badConfigurationObject = $configurationText | ConvertFrom-Json
    $badConfigurationObject.metadata.endpoint = 'https://github.com/ylc77/desktop-pet/releases/latest'
    [System.IO.File]::WriteAllText($badConfigurationPath, ($badConfigurationObject | ConvertTo-Json -Depth 8), $utf8NoBom)
    Test-Throws 'Hosting rejects a releases/latest URL that is not the latest.json asset' {
        Read-GitHubUpdaterHostingConfiguration -LiteralPath $badConfigurationPath
    } 'exactly match|GitHub Releases'
    $evilEndpointConfiguration = $configurationText | ConvertFrom-Json
    $evilEndpointConfiguration.metadata.endpoint = 'https://evil.com/desktop-pet/updater/beta/latest.json'
    $evilEndpointPath = [System.IO.Path]::Combine($temporaryRoot, 'evil-endpoint.json')
    [System.IO.File]::WriteAllText($evilEndpointPath, ($evilEndpointConfiguration | ConvertTo-Json -Depth 8), $utf8NoBom)
    Test-Throws 'Metadata endpoint on another host is rejected' {
        Read-GitHubUpdaterHostingConfiguration -LiteralPath $evilEndpointPath
    } 'exactly match|GitHub Releases'
    $extraPathConfiguration = $configurationText | ConvertFrom-Json
    $extraPathConfiguration.metadata.versionedEndpointTemplate = 'https://github.com/ylc77/desktop-pet/releases/download/v{version}/extra/latest.json'
    $extraPath = [System.IO.Path]::Combine($temporaryRoot, 'extra-path.json')
    [System.IO.File]::WriteAllText($extraPath, ($extraPathConfiguration | ConvertTo-Json -Depth 8), $utf8NoBom)
    Test-Throws 'Metadata template with an extra subpath is rejected' {
        Read-GitHubUpdaterHostingConfiguration -LiteralPath $extraPath
    } 'exactly match'

    $planScriptText = Get-Content -LiteralPath ([System.IO.Path]::Combine($updaterTools, 'plan-github-release.ps1')) -Raw -Encoding UTF8
    $verifyScriptText = Get-Content -LiteralPath ([System.IO.Path]::Combine($updaterTools, 'verify-github-release-assets.ps1')) -Raw -Encoding UTF8
    $githubCommonText = Get-Content -LiteralPath ([System.IO.Path]::Combine($updaterTools, 'github-release-common.ps1')) -Raw -Encoding UTF8
    $productionGitHubToolText = $githubCommonText + $planScriptText + $verifyScriptText
    Test-Equal 'GitHub release plan defaults to preview' $true ([bool]($planScriptText -match '-not \$ConfirmPlan -or \$WhatIfPreference'))
    Test-Equal 'GitHub release tools never create a release' $false ([bool]($productionGitHubToolText -match "'release','create'|release\s+create"))
    Test-Equal 'GitHub release tools never upload an asset' $false ([bool]($productionGitHubToolText -match "'release','upload'|release\s+upload"))
    Test-Equal 'GitHub release tools never edit or delete a release' $false ([bool]($productionGitHubToolText -match "'release','(?:edit|delete)'|release\s+(?:edit|delete)"))
    Test-Equal 'GitHub release tools never use a mutating API method' $false ([bool]($productionGitHubToolText -match "(?i)--method.{0,8}(?:POST|PATCH|PUT|DELETE)|'(?:POST|PATCH|PUT|DELETE)'"))
    Test-Equal 'GitHub release tools never push Git' $false ([bool]($productionGitHubToolText -match "(?i)git(?:\.exe)?\s+push|'push'"))
    Test-Equal 'Remote verification tool only uses release download' $true ([bool]($productionGitHubToolText -match "'release','download'"))
} finally {
    if ([System.IO.Directory]::Exists($temporaryRoot)) { [System.IO.Directory]::Delete($temporaryRoot, $true) }
}

$results | Format-Table -AutoSize
$hostIsPowerShell51 = $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
[pscustomobject]@{ Name='Windows PowerShell 5.1 host'; Passed=$hostIsPowerShell51; Details=$PSVersionTable.PSVersion.ToString() } | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -or -not $hostIsPowerShell51) { exit 1 }
