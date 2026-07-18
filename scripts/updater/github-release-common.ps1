Set-StrictMode -Version Latest

if ($null -eq (Get-Command Resolve-UpdaterPath -ErrorAction SilentlyContinue)) {
    . ([System.IO.Path]::Combine($PSScriptRoot, 'common.ps1'))
}

function Get-GitHubHostingPropertyValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-GitHubHostingRequiredBoolean {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    $value = Get-GitHubHostingPropertyValue -InputObject $InputObject -Name $Name
    if ($value -isnot [System.Boolean]) {
        throw "GitHub updater hosting property $Name must be a JSON Boolean."
    }
    return [System.Boolean]$value
}

function Assert-GitHubHostingExactObjectProperties {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$SchemaName,
        [Parameter(Mandatory)][string[]]$AllowedProperties
    )

    if ($null -eq $InputObject -or $InputObject -is [string] -or $InputObject -is [System.ValueType] -or
        $InputObject -is [System.Collections.IEnumerable]) {
        throw "$SchemaName must be a JSON object with the exact reviewed properties."
    }
    $allowed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($name in $AllowedProperties) { [void]$allowed.Add($name) }
    $actualNames = @($InputObject.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($actualNames.Count -ne $allowed.Count) {
        throw "$SchemaName must contain exactly the reviewed properties."
    }
    foreach ($name in $actualNames) {
        if (-not $allowed.Contains($name)) {
            throw "$SchemaName contains an unknown property."
        }
    }
}

function ConvertFrom-GitHubStrictJsonArray {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$ResponseName
    )

    $trimmed = $Text.Trim()
    if ($trimmed.Length -lt 2 -or $trimmed[0] -ne '[' -or $trimmed[$trimmed.Length - 1] -ne ']') {
        throw "$ResponseName must be a JSON array."
    }
    try { $document = $trimmed | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "$ResponseName is not valid JSON." }
    if ($document -isnot [System.Array]) { throw "$ResponseName must be a JSON array." }
    return ,$document
}

function Read-GitHubUpdaterHostingConfiguration {
    param([Parameter(Mandatory)][string]$LiteralPath)

    if (-not [System.IO.File]::Exists($LiteralPath)) { throw 'GitHub updater hosting configuration does not exist.' }
    $text = Get-FileTextWithoutBom -LiteralPath $LiteralPath
    Assert-NoUpdaterSensitiveMetadata -Text $text
    if ($text -match '(?i)"(?:privateKey|publicKey|password|accessToken|apiToken|secret)"\s*:') {
        throw 'GitHub updater hosting configuration must not contain key material, passwords, tokens, or secret fields.'
    }
    try { $configuration = $text | ConvertFrom-Json } catch { throw 'GitHub updater hosting configuration is not valid JSON.' }
    Assert-GitHubHostingExactObjectProperties -InputObject $configuration -SchemaName 'GitHub updater hosting configuration' -AllowedProperties @(
        'schemaVersion','enabled','provider','repository','identifier','channel','platform','installMode','release','metadata','status'
    )

    $schemaVersion = Get-GitHubHostingPropertyValue $configuration 'schemaVersion'
    if (($schemaVersion -isnot [System.Int32] -and $schemaVersion -isnot [System.Int64] -and
        $schemaVersion -isnot [System.Int16] -and $schemaVersion -isnot [System.Byte]) -or [System.Int64]$schemaVersion -ne 1) {
        throw 'Unsupported GitHub updater hosting configuration schema.'
    }
    if ([string](Get-GitHubHostingPropertyValue $configuration 'provider') -ne 'github-releases') {
        throw 'GitHub updater hosting provider must be github-releases.'
    }
    $repository = [string](Get-GitHubHostingPropertyValue $configuration 'repository')
    if ($repository -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]+$') {
        throw 'GitHub repository must use the owner/name form.'
    }
    if ($repository -cne 'ylc77/desktop-pet' -or [string](Get-GitHubHostingPropertyValue $configuration 'identifier') -cne 'dev.deskpet.framework') {
        throw 'GitHub updater hosting repository or application identifier does not match the reviewed release identity.'
    }
    if ([string](Get-GitHubHostingPropertyValue $configuration 'channel') -ne 'beta') {
        throw 'GitHub updater hosting configuration must use the beta channel.'
    }
    if ([string](Get-GitHubHostingPropertyValue $configuration 'platform') -ne 'windows-x86_64') {
        throw 'GitHub updater hosting configuration has an unexpected platform.'
    }
    if ([string](Get-GitHubHostingPropertyValue $configuration 'installMode') -ne 'passive') {
        throw 'GitHub updater hosting configuration must retain passive installation mode.'
    }
    [void](Get-GitHubHostingRequiredBoolean -InputObject $configuration -Name 'enabled')

    $release = Get-GitHubHostingPropertyValue $configuration 'release'
    Assert-GitHubHostingExactObjectProperties -InputObject $release -SchemaName 'GitHub updater release configuration' -AllowedProperties @(
        'tagPrefix','draft','prerelease','immutableVersionedAssets'
    )
    if ($null -eq $release -or [string](Get-GitHubHostingPropertyValue $release 'tagPrefix') -ne 'v' -or
        -not (Get-GitHubHostingRequiredBoolean -InputObject $release -Name 'draft') -or
        (Get-GitHubHostingRequiredBoolean -InputObject $release -Name 'prerelease') -or
        -not (Get-GitHubHostingRequiredBoolean -InputObject $release -Name 'immutableVersionedAssets')) {
        throw 'GitHub updater releases must be immutable and draft-first with v-prefixed version tags; the GitHub prerelease flag must remain false so releases/latest can select the beta release.'
    }

    $metadata = Get-GitHubHostingPropertyValue $configuration 'metadata'
    Assert-GitHubHostingExactObjectProperties -InputObject $metadata -SchemaName 'GitHub updater metadata configuration' -AllowedProperties @(
        'provider','ownerConfirmed','endpoint','versionedEndpointTemplate','publishAfterRemoteVerification'
    )
    if ($null -eq $metadata -or [string](Get-GitHubHostingPropertyValue $metadata 'provider') -ne 'github-releases' -or
        -not (Get-GitHubHostingRequiredBoolean -InputObject $metadata -Name 'publishAfterRemoteVerification')) {
        throw 'GitHub updater metadata must use GitHub Releases and publish only after remote verification.'
    }
    [void](Get-GitHubHostingRequiredBoolean -InputObject $metadata -Name 'ownerConfirmed')
    $endpoint = Assert-UpdaterHttpsUrl -Url ([string](Get-GitHubHostingPropertyValue $metadata 'endpoint'))
    $versionedTemplate = [string](Get-GitHubHostingPropertyValue $metadata 'versionedEndpointTemplate')
    if ($versionedTemplate -notmatch '\{version\}') { throw 'Versioned metadata endpoint template must contain {version}.' }
    $templateProbe = Assert-UpdaterHttpsUrl -Url ($versionedTemplate.Replace('{version}', '0.0.0-test.1'))
    $expectedEndpoint = 'https://github.com/ylc77/desktop-pet/releases/latest/download/latest.json'
    $expectedVersionedTemplate = 'https://github.com/ylc77/desktop-pet/releases/download/v{version}/latest.json'
    if (-not [string]::Equals($endpoint, $expectedEndpoint, [StringComparison]::Ordinal) -or
        -not [string]::Equals($versionedTemplate, $expectedVersionedTemplate, [StringComparison]::Ordinal)) {
        throw 'GitHub Releases metadata endpoint and versioned template must exactly match the reviewed beta paths.'
    }

    return $configuration
}

function Get-GitHubUpdaterReleaseTag {
    param(
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][string]$Version
    )

    [void](Get-SemVerParts -Version $Version)
    $release = Get-GitHubHostingPropertyValue $Configuration 'release'
    return [string](Get-GitHubHostingPropertyValue $release 'tagPrefix') + $Version
}

function Get-GitHubUpdaterAssetUrl {
    param(
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$AssetName
    )

    if ([string]::IsNullOrWhiteSpace($AssetName) -or [System.IO.Path]::GetFileName($AssetName) -ne $AssetName) {
        throw 'GitHub Release asset name must be a filename without directory components.'
    }
    $repository = [string](Get-GitHubHostingPropertyValue $Configuration 'repository')
    $tag = Get-GitHubUpdaterReleaseTag -Configuration $Configuration -Version $Version
    $escapedTag = [Uri]::EscapeDataString($tag)
    $escapedAsset = [Uri]::EscapeDataString($AssetName)
    return Assert-UpdaterHttpsUrl -Url "https://github.com/$repository/releases/download/$escapedTag/$escapedAsset"
}

function Get-GitHubUpdaterVersionedMetadataUrl {
    param(
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][string]$Version
    )

    [void](Get-SemVerParts -Version $Version)
    $metadata = Get-GitHubHostingPropertyValue $Configuration 'metadata'
    $template = [string](Get-GitHubHostingPropertyValue $metadata 'versionedEndpointTemplate')
    return Assert-UpdaterHttpsUrl -Url ($template.Replace('{version}', [Uri]::EscapeDataString($Version)))
}

function Get-GitHubUpdaterQualifiedRepository {
    param([Parameter(Mandatory)][string]$Repository)

    if ($Repository -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]+$') {
        throw 'GitHub repository must use the owner/name form.'
    }
    return "github.com/$Repository"
}

function Get-GitHubUpdaterReleaseDownloadArguments {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string[]]$AssetNames,
        [Parameter(Mandatory)][string]$DestinationDirectory
    )

    if ($Tag -notmatch '^v[0-9A-Za-z.+-]+$' -or $AssetNames.Count -eq 0) {
        throw 'GitHub Release download tag or asset list is invalid.'
    }
    if (-not [System.IO.Path]::IsPathRooted($DestinationDirectory)) {
        throw 'GitHub Release download destination must be an absolute path.'
    }
    $uniqueAssetNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $arguments = @('release','download',$Tag,'--repo',(Get-GitHubUpdaterQualifiedRepository -Repository $Repository))
    foreach ($assetName in $AssetNames) {
        if ([string]::IsNullOrWhiteSpace($assetName) -or [System.IO.Path]::GetFileName($assetName) -cne $assetName -or
            -not $uniqueAssetNames.Add($assetName)) {
            throw 'GitHub Release download asset names must be unique filenames.'
        }
        $arguments += @('--pattern',$assetName)
    }
    $arguments += @('--dir',[System.IO.Path]::GetFullPath($DestinationDirectory))
    return $arguments
}

function Test-GitHubUpdaterChecksumDocument {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][hashtable]$ExpectedHashes
    )

    $text = Get-FileTextWithoutBom -LiteralPath $LiteralPath
    Assert-NoUpdaterSensitiveMetadata -Text $text
    $actual = @{}
    foreach ($line in @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if ($line -notmatch '^(?<hash>[A-Fa-f0-9]{64})\s{2,}(?<name>[^\\/\r\n]+)$') {
            throw 'SHA256SUMS.txt contains an invalid or path-bearing entry.'
        }
        $name = [string]$Matches['name']
        if ($actual.ContainsKey($name)) { throw 'SHA256SUMS.txt contains a duplicate filename.' }
        $actual[$name] = ([string]$Matches['hash']).ToUpperInvariant()
    }
    if ($actual.Count -ne $ExpectedHashes.Count) { return $false }
    foreach ($name in $ExpectedHashes.Keys) {
        if (-not $actual.ContainsKey($name) -or -not [string]::Equals([string]$actual[$name], [string]$ExpectedHashes[$name], [StringComparison]::Ordinal)) {
            return $false
        }
    }
    return $true
}

function Invoke-GitHubUpdaterReadOnlyCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [scriptblock]$CommandInvoker
    )

    if ($null -ne $CommandInvoker) {
        $result = & $CommandInvoker $FilePath $ArgumentList
        if ($null -eq $result) { throw 'Injected GitHub command invoker returned no result.' }
        return $result
    }
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $FilePath @ArgumentList 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    return [pscustomobject]@{ ExitCode=$exitCode; Output=($output -join [Environment]::NewLine) }
}

function ConvertTo-GitHubRedactedLogin {
    param([AllowNull()][string]$Login)

    if ([string]::IsNullOrWhiteSpace($Login)) { return '<unavailable>' }
    $visibleLength = [Math]::Min(2, $Login.Length)
    return $Login.Substring(0, $visibleLength) + '***'
}

function ConvertFrom-GitHubRemoteUrl {
    param([AllowNull()][string]$RemoteUrl)

    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) { return $null }
    $value = $RemoteUrl.Trim()
    $patterns = @(
        '^https://github\.com/(?<repo>[A-Za-z0-9-]+/[A-Za-z0-9._-]+?)(?:\.git)?/?$',
        '^git@github\.com:(?<repo>[A-Za-z0-9-]+/[A-Za-z0-9._-]+?)(?:\.git)?$',
        '^ssh://git@github\.com/(?<repo>[A-Za-z0-9-]+/[A-Za-z0-9._-]+?)(?:\.git)?/?$'
    )
    foreach ($pattern in $patterns) {
        if ($value -match $pattern) { return [string]$Matches['repo'] }
    }
    return $null
}

function Get-GitHubUpdaterLocalGitState {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$ExpectedRepository,
        [scriptblock]$GitInvoker
    )

    $state = Get-UpdaterGitState -RepositoryRoot $RepositoryRoot
    if ($null -ne $GitInvoker) {
        $originResult = & $GitInvoker $RepositoryRoot
    } else {
        $savedErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $originOutput = @(& git -C $RepositoryRoot remote get-url origin 2>$null)
            $originExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedErrorActionPreference
        }
        $originResult = [pscustomobject]@{ ExitCode=$originExitCode; Output=$(if ($originOutput.Count) { [string]$originOutput[0] } else { '' }) }
    }
    $originRepository = if ([int](Get-GitHubHostingPropertyValue $originResult 'ExitCode') -eq 0) {
        ConvertFrom-GitHubRemoteUrl -RemoteUrl ([string](Get-GitHubHostingPropertyValue $originResult 'Output'))
    } else { $null }
    return [pscustomobject]@{
        Commit = [string]$state.Commit
        DirtyWorktree = [bool]$state.DirtyWorktree
        OriginConfigured = -not [string]::IsNullOrWhiteSpace($originRepository)
        OriginMatches = (-not [string]::IsNullOrWhiteSpace($originRepository) -and
            [string]::Equals($originRepository, $ExpectedRepository, [StringComparison]::OrdinalIgnoreCase))
        OriginRepository = $(if ([string]::IsNullOrWhiteSpace($originRepository)) { '<unavailable>' } else { $originRepository })
    }
}

function New-GitHubUpdaterRepositoryFailureState {
    param(
        [bool]$CliAvailable = $true,
        [bool]$Authenticated = $false
    )

    return [pscustomobject]@{
        CliAvailable=$CliAvailable; Authenticated=$Authenticated; QueriesSucceeded=$false
        RepositoryMatches=$false; PublicRepository=$false; ViewerPermission='<unavailable>'; PermissionSufficient=$false
        OperatorLogin='<unavailable>'; HeadCommitExists=$false; TargetTagStateSatisfied=$false
        TargetReleaseStateSatisfied=$false; AssetNameStateSatisfied=$false; TagCommitMatches=$false
        ReleaseTargetCommitMatches=$false; ReleaseDraftMatches=$false; ReleasePrereleaseMatches=$false
    }
}

function Expand-GitHubUpdaterReleases {
    param([AllowNull()][object]$InputObject)

    foreach ($item in @($InputObject)) {
        if ($null -eq $item) { continue }
        if ($null -ne $item.PSObject.Properties['tag_name']) {
            Write-Output $item
        } elseif ($item -is [System.Collections.IEnumerable] -and $item -isnot [string]) {
            foreach ($nested in $item) { Write-Output (Expand-GitHubUpdaterReleases -InputObject $nested) }
        }
    }
}

function Resolve-GitHubUpdaterRemoteCommit {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)][string]$GitHubCliPath,
        [scriptblock]$CommandInvoker
    )

    if ([string]::IsNullOrWhiteSpace($Reference) -or $Reference -match '[\x00-\x1F\x7F]') {
        return [pscustomobject]@{ Succeeded=$false; Commit='' }
    }
    $escapedReference = [Uri]::EscapeDataString($Reference)
    $result = Invoke-GitHubUpdaterReadOnlyCommand -FilePath $GitHubCliPath -ArgumentList @(
        'api',"repos/$Repository/commits/$escapedReference",'--hostname','github.com','--jq','.sha'
    ) -CommandInvoker $CommandInvoker
    if ([int](Get-GitHubHostingPropertyValue $result 'ExitCode') -ne 0) {
        return [pscustomobject]@{ Succeeded=$false; Commit='' }
    }
    $commit = ([string](Get-GitHubHostingPropertyValue $result 'Output')).Trim()
    if ($commit -notmatch '^[A-Fa-f0-9]{40,64}$') {
        return [pscustomobject]@{ Succeeded=$false; Commit='' }
    }
    return [pscustomobject]@{ Succeeded=$true; Commit=$commit }
}

function Get-GitHubUpdaterRepositoryState {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$HeadCommit,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string[]]$AssetNames,
        [string[]]$GloballyUniqueAssetNames,
        [ValidateSet('Absent','Draft','Present')][string]$ReleaseExpectation = 'Absent',
        [bool]$ExpectedPrerelease = $true,
        [scriptblock]$CommandInvoker,
        [string]$GitHubCliPath
    )

    if ($HeadCommit -notmatch '^[A-Fa-f0-9]{40,64}$') { return New-GitHubUpdaterRepositoryFailureState }
    if ($Tag -notmatch '^v[0-9A-Za-z.+-]+$' -or $AssetNames.Count -eq 0) { return New-GitHubUpdaterRepositoryFailureState }
    $expectedAssetSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($assetName in $AssetNames) {
        if ([string]::IsNullOrWhiteSpace($assetName) -or [System.IO.Path]::GetFileName($assetName) -cne $assetName -or
            -not $expectedAssetSet.Add($assetName)) {
            return New-GitHubUpdaterRepositoryFailureState
        }
    }
    if ($null -eq $GloballyUniqueAssetNames -or $GloballyUniqueAssetNames.Count -eq 0) {
        $GloballyUniqueAssetNames = $AssetNames
    }
    $globalAssetSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($assetName in $GloballyUniqueAssetNames) {
        if ([string]::IsNullOrWhiteSpace($assetName) -or
            -not $expectedAssetSet.Contains($assetName) -or
            -not $globalAssetSet.Add($assetName)) {
            return New-GitHubUpdaterRepositoryFailureState
        }
    }
    if ([string]::IsNullOrWhiteSpace($GitHubCliPath)) {
        $gh = Get-Command gh.exe -ErrorAction SilentlyContinue
        if ($null -eq $gh) { $gh = Get-Command gh -ErrorAction SilentlyContinue }
        if ($null -eq $gh) { return New-GitHubUpdaterRepositoryFailureState -CliAvailable $false }
        $GitHubCliPath = $gh.Source
    }
    $auth = Invoke-GitHubUpdaterReadOnlyCommand -FilePath $GitHubCliPath -ArgumentList @('auth','status','--hostname','github.com') -CommandInvoker $CommandInvoker
    if ([int](Get-GitHubHostingPropertyValue $auth 'ExitCode') -ne 0) {
        return New-GitHubUpdaterRepositoryFailureState -CliAvailable $true -Authenticated $false
    }
    try {
        $userResult = Invoke-GitHubUpdaterReadOnlyCommand -FilePath $GitHubCliPath -ArgumentList @('api','user','--hostname','github.com','--jq','.login') -CommandInvoker $CommandInvoker
        $repositoryResult = Invoke-GitHubUpdaterReadOnlyCommand -FilePath $GitHubCliPath -ArgumentList @(
            'repo','view',(Get-GitHubUpdaterQualifiedRepository -Repository $Repository),'--json','nameWithOwner,isPrivate,visibility,url,viewerPermission'
        ) -CommandInvoker $CommandInvoker
        $commitResult = Invoke-GitHubUpdaterReadOnlyCommand -FilePath $GitHubCliPath -ArgumentList @(
            'api',"repos/$Repository/commits/$HeadCommit",'--hostname','github.com','--jq','.sha'
        ) -CommandInvoker $CommandInvoker
        $tagResult = Invoke-GitHubUpdaterReadOnlyCommand -FilePath $GitHubCliPath -ArgumentList @(
            'api',"repos/$Repository/git/matching-refs/tags/$Tag",'--hostname','github.com'
        ) -CommandInvoker $CommandInvoker
        $releasesResult = Invoke-GitHubUpdaterReadOnlyCommand -FilePath $GitHubCliPath -ArgumentList @(
            'api',"repos/$Repository/releases?per_page=100",'--hostname','github.com','--paginate','--slurp'
        ) -CommandInvoker $CommandInvoker
        foreach ($result in @($userResult,$repositoryResult,$commitResult,$tagResult,$releasesResult)) {
            if ([int](Get-GitHubHostingPropertyValue $result 'ExitCode') -ne 0) {
                return New-GitHubUpdaterRepositoryFailureState -CliAvailable $true -Authenticated $true
            }
        }
        $login = ([string](Get-GitHubHostingPropertyValue $userResult 'Output')).Trim()
        if ($login -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$') { throw 'invalid login' }
        $repositoryDocument = [string](Get-GitHubHostingPropertyValue $repositoryResult 'Output') | ConvertFrom-Json
        $isPrivate = Get-GitHubHostingRequiredBoolean -InputObject $repositoryDocument -Name 'isPrivate'
        $commitSha = ([string](Get-GitHubHostingPropertyValue $commitResult 'Output')).Trim()
        $tagDocument = ConvertFrom-GitHubStrictJsonArray -Text ([string](Get-GitHubHostingPropertyValue $tagResult 'Output')) `
            -ResponseName 'GitHub tag response'
        $releasePages = ConvertFrom-GitHubStrictJsonArray -Text ([string](Get-GitHubHostingPropertyValue $releasesResult 'Output')) `
            -ResponseName 'GitHub release response'
        $releases = @(Expand-GitHubUpdaterReleases -InputObject $releasePages)
    } catch {
        return New-GitHubUpdaterRepositoryFailureState -CliAvailable $true -Authenticated $true
    }

    $nameWithOwner = [string](Get-GitHubHostingPropertyValue $repositoryDocument 'nameWithOwner')
    $visibility = [string](Get-GitHubHostingPropertyValue $repositoryDocument 'visibility')
    $viewerPermission = [string](Get-GitHubHostingPropertyValue $repositoryDocument 'viewerPermission')
    $permissionSufficient = $viewerPermission -in @('WRITE','MAINTAIN','ADMIN')
    $matchingTagRefs = @($tagDocument | Where-Object { [string](Get-GitHubHostingPropertyValue $_ 'ref') -ceq "refs/tags/$Tag" })
    $matchingReleases = @($releases | Where-Object { [string](Get-GitHubHostingPropertyValue $_ 'tag_name') -ceq $Tag })
    $matchingAssetNames = @($releases | ForEach-Object {
        foreach ($asset in @((Get-GitHubHostingPropertyValue $_ 'assets'))) {
            $assetName = [string](Get-GitHubHostingPropertyValue $asset 'name')
            if ($GloballyUniqueAssetNames -ccontains $assetName) { $assetName }
        }
    })
    $queriesSucceeded = $true
    $tagCommitMatches = $false
    $releaseTargetCommitMatches = $false
    $releaseDraftMatches = $false
    $releasePrereleaseMatches = $false
    if ($ReleaseExpectation -eq 'Absent') {
        $tagState = $matchingTagRefs.Count -eq 0
        $releaseState = $matchingReleases.Count -eq 0
        $assetState = $matchingAssetNames.Count -eq 0
    } else {
        $tagCountValid = $(if ($ReleaseExpectation -eq 'Draft') { $matchingTagRefs.Count -le 1 } else { $matchingTagRefs.Count -eq 1 })
        if ($matchingTagRefs.Count -eq 0) {
            $tagCommitMatches = $ReleaseExpectation -eq 'Draft'
        } elseif ($matchingTagRefs.Count -eq 1) {
            $tagObject = Get-GitHubHostingPropertyValue $matchingTagRefs[0] 'object'
            $tagObjectType = [string](Get-GitHubHostingPropertyValue $tagObject 'type')
            $tagObjectSha = [string](Get-GitHubHostingPropertyValue $tagObject 'sha')
            if ($tagObjectType -ceq 'commit' -and $tagObjectSha -match '^[A-Fa-f0-9]{40,64}$') {
                $tagCommitMatches = [string]::Equals($tagObjectSha,$HeadCommit,[StringComparison]::OrdinalIgnoreCase)
            } elseif ($tagObjectType -ceq 'tag' -and $tagObjectSha -match '^[A-Fa-f0-9]{40,64}$') {
                $resolvedTag = Resolve-GitHubUpdaterRemoteCommit -Repository $Repository -Reference $Tag `
                    -GitHubCliPath $GitHubCliPath -CommandInvoker $CommandInvoker
                $queriesSucceeded = [bool]$resolvedTag.Succeeded
                $tagCommitMatches = $queriesSucceeded -and [string]::Equals([string]$resolvedTag.Commit,$HeadCommit,[StringComparison]::OrdinalIgnoreCase)
            }
        }
        $tagState = $tagCountValid -and $tagCommitMatches
        $releaseState = $false
        $assetState = $false
        if ($matchingReleases.Count -eq 1) {
            $targetRelease = $matchingReleases[0]
            try {
                $releaseDraft = Get-GitHubHostingRequiredBoolean -InputObject $targetRelease -Name 'draft'
                $releasePrerelease = Get-GitHubHostingRequiredBoolean -InputObject $targetRelease -Name 'prerelease'
                $releaseDraftMatches = $releaseDraft -eq ($ReleaseExpectation -eq 'Draft')
                $releasePrereleaseMatches = $releasePrerelease -eq $ExpectedPrerelease
            } catch {
                $releaseDraftMatches = $false
                $releasePrereleaseMatches = $false
            }
            $targetCommitish = [string](Get-GitHubHostingPropertyValue $targetRelease 'target_commitish')
            if ($targetCommitish -match '^[A-Fa-f0-9]{40,64}$') {
                $releaseTargetCommitMatches = [string]::Equals($targetCommitish,$HeadCommit,[StringComparison]::OrdinalIgnoreCase)
            } elseif (-not [string]::IsNullOrWhiteSpace($targetCommitish)) {
                $resolvedTarget = Resolve-GitHubUpdaterRemoteCommit -Repository $Repository -Reference $targetCommitish `
                    -GitHubCliPath $GitHubCliPath -CommandInvoker $CommandInvoker
                $queriesSucceeded = $queriesSucceeded -and [bool]$resolvedTarget.Succeeded
                $releaseTargetCommitMatches = [bool]$resolvedTarget.Succeeded -and `
                    [string]::Equals([string]$resolvedTarget.Commit,$HeadCommit,[StringComparison]::OrdinalIgnoreCase)
            }
            $targetAssets = @((Get-GitHubHostingPropertyValue $targetRelease 'assets') | ForEach-Object {
                [string](Get-GitHubHostingPropertyValue $_ 'name')
            })
            $assetState = $targetAssets.Count -eq $AssetNames.Count
            if ($assetState) {
                foreach ($expectedAssetName in $AssetNames) {
                    if (@($targetAssets | Where-Object { [string]$_ -ceq [string]$expectedAssetName }).Count -ne 1) {
                        $assetState = $false
                    }
                }
            }
            $releaseState = $releaseDraftMatches -and $releasePrereleaseMatches -and $releaseTargetCommitMatches
        }
    }
    return [pscustomobject]@{
        CliAvailable=$true; Authenticated=$true; QueriesSucceeded=$queriesSucceeded
        RepositoryMatches=[string]::Equals($nameWithOwner,$Repository,[StringComparison]::OrdinalIgnoreCase)
        PublicRepository=(-not $isPrivate -and [string]::Equals($visibility,'PUBLIC',[StringComparison]::OrdinalIgnoreCase))
        ViewerPermission=$viewerPermission; PermissionSufficient=$permissionSufficient
        OperatorLogin=ConvertTo-GitHubRedactedLogin -Login $login
        HeadCommitExists=[string]::Equals($commitSha,$HeadCommit,[StringComparison]::OrdinalIgnoreCase)
        TargetTagStateSatisfied=$tagState; TargetReleaseStateSatisfied=$releaseState; AssetNameStateSatisfied=$assetState
        TagCommitMatches=$tagCommitMatches; ReleaseTargetCommitMatches=$releaseTargetCommitMatches
        ReleaseDraftMatches=$releaseDraftMatches; ReleasePrereleaseMatches=$releasePrereleaseMatches
    }
}

function Assert-GitHubUpdaterReleaseBundle {
    param(
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$CurrentVersion,
        [Parameter(Mandatory)][string]$ArtifactPath,
        [Parameter(Mandatory)][string]$SignaturePath,
        [Parameter(Mandatory)][string]$PublicKeyPath,
        [Parameter(Mandatory)][string]$LatestJsonPath,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$ChecksumPath,
        [scriptblock]$SignatureVerifier
    )

    [void](Get-SemVerParts -Version $Version)
    [void](Get-SemVerParts -Version $CurrentVersion)
    Assert-UpdaterVersionIncrease -CurrentVersion $CurrentVersion -Version $Version
    foreach ($path in @($ArtifactPath,$SignaturePath,$PublicKeyPath,$LatestJsonPath,$ManifestPath,$ChecksumPath)) {
        if (-not [System.IO.File]::Exists($path)) { throw 'A required updater release bundle file does not exist.' }
    }
    Assert-UpdaterSignatureBinding -ArtifactPath $ArtifactPath -SignaturePath $SignaturePath
    $artifactName = [System.IO.Path]::GetFileName($ArtifactPath)
    $signatureName = [System.IO.Path]::GetFileName($SignaturePath)
    $latestName = [System.IO.Path]::GetFileName($LatestJsonPath)
    $artifactSize = (Get-Item -LiteralPath $ArtifactPath).Length
    $artifactHash = Get-Sha256Hex -LiteralPath $ArtifactPath
    $signatureHash = Get-Sha256Hex -LiteralPath $SignaturePath
    $latestHash = Get-Sha256Hex -LiteralPath $LatestJsonPath
    $signatureText = Get-UpdaterSignatureText -SignaturePath $SignaturePath
    $fingerprint = Get-UpdaterPublicKeyFingerprint -LiteralPath $PublicKeyPath
    $downloadUrl = Get-GitHubUpdaterAssetUrl -Configuration $Configuration -Version $Version -AssetName $artifactName
    $metadata = Get-GitHubHostingPropertyValue $Configuration 'metadata'
    $endpoint = [string](Get-GitHubHostingPropertyValue $metadata 'endpoint')
    [void](Assert-UpdaterArtifactBinding -ArtifactPath $ArtifactPath -Version $Version -DownloadUrl $downloadUrl)

    $manifestText = Get-FileTextWithoutBom -LiteralPath $ManifestPath
    Assert-NoUpdaterSensitiveMetadata -Text $manifestText
    try { $manifest = $manifestText | ConvertFrom-Json } catch { throw 'Updater release manifest is not valid JSON.' }
    Assert-GitHubHostingExactObjectProperties -InputObject $manifest -SchemaName 'Updater release manifest' -AllowedProperties @(
        'schemaVersion','applicationName','identifier','version','currentVersion','platform','artifactFile','signatureFile',
        'latestJsonFile','artifactSizeBytes','artifactSha256','signatureSha256','latestJsonSha256','publicKeyFingerprint',
        'downloadUrl','endpoint','installMode','preparedAtUtc','gitCommit','dirtyWorktree','cryptographicSignatureVerified'
    )
    $schemaVersion = Get-GitHubHostingPropertyValue $manifest 'schemaVersion'
    if (($schemaVersion -isnot [System.Int32] -and $schemaVersion -isnot [System.Int64] -and
        $schemaVersion -isnot [System.Int16] -and $schemaVersion -isnot [System.Byte]) -or [System.Int64]$schemaVersion -ne 1) {
        throw 'Updater release manifest schemaVersion must be the integer 1.'
    }
    if ([string](Get-GitHubHostingPropertyValue $manifest 'version') -cne $Version -or
        [string](Get-GitHubHostingPropertyValue $manifest 'currentVersion') -cne $CurrentVersion) {
        throw 'Updater release manifest version transition does not match the expected release.'
    }
    if ([string](Get-GitHubHostingPropertyValue $manifest 'identifier') -cne [string](Get-GitHubHostingPropertyValue $Configuration 'identifier') -or
        [string](Get-GitHubHostingPropertyValue $manifest 'platform') -cne [string](Get-GitHubHostingPropertyValue $Configuration 'platform') -or
        [string](Get-GitHubHostingPropertyValue $manifest 'installMode') -cne [string](Get-GitHubHostingPropertyValue $Configuration 'installMode')) {
        throw 'Updater release manifest application identity, platform, or install mode is invalid.'
    }
    $dirty = Get-GitHubHostingRequiredBoolean -InputObject $manifest -Name 'dirtyWorktree'
    $cryptographicResult = Get-GitHubHostingRequiredBoolean -InputObject $manifest -Name 'cryptographicSignatureVerified'
    if ($dirty -or -not $cryptographicResult) { throw 'Updater release manifest is dirty or lacks a verified cryptographic result.' }
    $manifestCommit = [string](Get-GitHubHostingPropertyValue $manifest 'gitCommit')
    if ($manifestCommit -notmatch '^[A-Fa-f0-9]{40,64}$') { throw 'Updater release manifest has no valid Git commit.' }
    if ([string](Get-GitHubHostingPropertyValue $manifest 'artifactFile') -cne $artifactName -or
        [string](Get-GitHubHostingPropertyValue $manifest 'signatureFile') -cne $signatureName -or
        [string](Get-GitHubHostingPropertyValue $manifest 'latestJsonFile') -cne $latestName) {
        throw 'Updater release manifest filenames do not bind the exact bundle.'
    }
    if ([long](Get-GitHubHostingPropertyValue $manifest 'artifactSizeBytes') -ne $artifactSize -or
        [string](Get-GitHubHostingPropertyValue $manifest 'artifactSha256') -cne $artifactHash -or
        [string](Get-GitHubHostingPropertyValue $manifest 'signatureSha256') -cne $signatureHash -or
        [string](Get-GitHubHostingPropertyValue $manifest 'latestJsonSha256') -cne $latestHash) {
        throw 'Updater release manifest size or SHA-256 binding is invalid.'
    }
    if ([string](Get-GitHubHostingPropertyValue $manifest 'publicKeyFingerprint') -cne $fingerprint -or
        [string](Get-GitHubHostingPropertyValue $manifest 'downloadUrl') -cne $downloadUrl -or
        [string](Get-GitHubHostingPropertyValue $manifest 'endpoint') -cne $endpoint) {
        throw 'Updater release manifest public key, download URL, or endpoint binding is invalid.'
    }

    [void](Test-UpdaterLatestDocument -LatestJsonPath $LatestJsonPath -CurrentVersion $CurrentVersion -ExpectedVersion $Version `
        -ExpectedPlatform ([string](Get-GitHubHostingPropertyValue $Configuration 'platform')) -ExpectedArtifactSizeBytes $artifactSize)
    $latestText = Get-FileTextWithoutBom -LiteralPath $LatestJsonPath
    try { $latest = $latestText | ConvertFrom-Json } catch { throw 'Updater latest metadata is not valid JSON.' }
    $platform = [string](Get-GitHubHostingPropertyValue $Configuration 'platform')
    $latestProperty = $latest.platforms.PSObject.Properties[$platform]
    if ($null -eq $latestProperty) { throw 'Updater latest metadata lacks the expected platform.' }
    $latestEntry = $latestProperty.Value
    if ([string](Get-GitHubHostingPropertyValue $latest 'version') -cne $Version -or
        [string](Get-GitHubHostingPropertyValue $latestEntry 'url') -cne $downloadUrl -or
        [string](Get-GitHubHostingPropertyValue $latestEntry 'signature') -cne $signatureText -or
        [long](Get-GitHubHostingPropertyValue $latestEntry 'size') -ne $artifactSize) {
        throw 'Updater latest metadata does not bind the exact versioned artifact.'
    }
    if (-not (Test-GitHubUpdaterChecksumDocument -LiteralPath $ChecksumPath -ExpectedHashes @{
        $artifactName=$artifactHash; $signatureName=$signatureHash; $latestName=$latestHash
    })) { throw 'Updater SHA256SUMS.txt does not bind the exact release bundle.' }
    $signatureVerified = if ($null -ne $SignatureVerifier) {
        [bool](& $SignatureVerifier $ArtifactPath $SignaturePath $PublicKeyPath)
    } else {
        [bool](Test-UpdaterArtifactSignature -ArtifactPath $ArtifactPath -SignaturePath $SignaturePath -PublicKeyPath $PublicKeyPath)
    }
    if (-not $signatureVerified) { throw 'Updater release artifact failed cryptographic signature verification.' }
    return [pscustomobject]@{
        Valid=$true; ManifestCommit=$manifestCommit; ArtifactName=$artifactName; SignatureName=$signatureName
        LatestJsonName=$latestName; ArtifactSha256=$artifactHash; SignatureSha256=$signatureHash
        LatestJsonSha256=$latestHash; PublicKeyFingerprint=$fingerprint; DownloadUrl=$downloadUrl; Endpoint=$endpoint
    }
}

function New-GitHubUpdaterReleasePlan {
    param(
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$CurrentVersion,
        [Parameter(Mandatory)][string]$ArtifactPath,
        [Parameter(Mandatory)][string]$SignaturePath,
        [Parameter(Mandatory)][string]$PublicKeyPath,
        [Parameter(Mandatory)][string]$LatestJsonPath,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$ChecksumPath,
        [Parameter(Mandatory)][object]$GitState,
        [Parameter(Mandatory)][object]$GitHubState,
        [scriptblock]$SignatureVerifier
    )

    [void](Get-SemVerParts -Version $Version)
    [void](Get-SemVerParts -Version $CurrentVersion)
    Assert-UpdaterVersionIncrease -CurrentVersion $CurrentVersion -Version $Version
    foreach ($path in @($ArtifactPath,$SignaturePath,$PublicKeyPath,$LatestJsonPath,$ManifestPath,$ChecksumPath)) {
        if (-not [System.IO.File]::Exists($path)) { throw 'A required GitHub updater release input file does not exist.' }
    }
    Assert-UpdaterSignatureBinding -ArtifactPath $ArtifactPath -SignaturePath $SignaturePath
    $artifactName = [System.IO.Path]::GetFileName($ArtifactPath)
    $signatureName = [System.IO.Path]::GetFileName($SignaturePath)
    $downloadUrl = Get-GitHubUpdaterAssetUrl -Configuration $Configuration -Version $Version -AssetName $artifactName
    [void](Assert-UpdaterArtifactBinding -ArtifactPath $ArtifactPath -Version $Version -DownloadUrl $downloadUrl)
    $metadata = Get-GitHubHostingPropertyValue $Configuration 'metadata'
    $endpoint = Assert-UpdaterHttpsUrl -Url ([string](Get-GitHubHostingPropertyValue $metadata 'endpoint'))
    $versionedMetadataUrl = Get-GitHubUpdaterVersionedMetadataUrl -Configuration $Configuration -Version $Version
    $signatureText = Get-UpdaterSignatureText -SignaturePath $SignaturePath
    $fingerprint = Get-UpdaterPublicKeyFingerprint -LiteralPath $PublicKeyPath
    $artifactHash = Get-Sha256Hex -LiteralPath $ArtifactPath
    $signatureHash = Get-Sha256Hex -LiteralPath $SignaturePath
    $latestHash = Get-Sha256Hex -LiteralPath $LatestJsonPath
    $artifactSize = (Get-Item -LiteralPath $ArtifactPath).Length
    [void](Test-UpdaterLatestDocument -LatestJsonPath $LatestJsonPath -CurrentVersion $CurrentVersion -ExpectedVersion $Version `
        -ExpectedPlatform ([string](Get-GitHubHostingPropertyValue $Configuration 'platform')) -ExpectedArtifactSizeBytes $artifactSize)
    $latest = Get-FileTextWithoutBom -LiteralPath $LatestJsonPath | ConvertFrom-Json
    $platform = [string](Get-GitHubHostingPropertyValue $Configuration 'platform')
    $latestEntry = $latest.platforms.PSObject.Properties[$platform].Value

    $manifestText = Get-FileTextWithoutBom -LiteralPath $ManifestPath
    Assert-NoUpdaterSensitiveMetadata -Text $manifestText
    try { $manifest = $manifestText | ConvertFrom-Json } catch { throw 'Updater release manifest is not valid JSON.' }
    $checksumValid = Test-GitHubUpdaterChecksumDocument -LiteralPath $ChecksumPath -ExpectedHashes @{
        $artifactName=$artifactHash
        $signatureName=$signatureHash
        ([System.IO.Path]::GetFileName($LatestJsonPath))=$latestHash
    }
    try {
        $manifestDirty = Get-GitHubHostingRequiredBoolean -InputObject $manifest -Name 'dirtyWorktree'
        $manifestCryptographic = Get-GitHubHostingRequiredBoolean -InputObject $manifest -Name 'cryptographicSignatureVerified'
    } catch {
        $manifestDirty = $true
        $manifestCryptographic = $false
    }
    $signatureVerified = $false
    try {
        $signatureResult = if ($null -ne $SignatureVerifier) {
            & $SignatureVerifier $ArtifactPath $SignaturePath $PublicKeyPath
        } else {
            Test-UpdaterArtifactSignature -ArtifactPath $ArtifactPath -SignaturePath $SignaturePath -PublicKeyPath $PublicKeyPath
        }
        $signatureVerified = $signatureResult -is [System.Boolean] -and [System.Boolean]$signatureResult
    } catch {
        $signatureVerified = $false
    }
    $capturedSignatureResult = $signatureVerified
    $validatedSignatureVerifier = {
        param($ValidatedArtifact,$ValidatedSignature,$ValidatedPublicKey)
        return $capturedSignatureResult
    }.GetNewClosure()
    $completeBundleValid = $false
    try {
        $completeBundle = Assert-GitHubUpdaterReleaseBundle -Configuration $Configuration -Version $Version -CurrentVersion $CurrentVersion `
            -ArtifactPath $ArtifactPath -SignaturePath $SignaturePath -PublicKeyPath $PublicKeyPath -LatestJsonPath $LatestJsonPath `
            -ManifestPath $ManifestPath -ChecksumPath $ChecksumPath -SignatureVerifier $validatedSignatureVerifier
        $completeBundleValid = $completeBundle.Valid -is [System.Boolean] -and [System.Boolean]$completeBundle.Valid
    } catch {
        $completeBundleValid = $false
    }
    $checks = @(
        [pscustomobject]@{ Name='Hosting configuration enabled'; Passed=(Get-GitHubHostingRequiredBoolean -InputObject $Configuration -Name 'enabled'); Details='Owner-controlled switch must be enabled only after prerequisites are complete.' },
        [pscustomobject]@{ Name='Metadata hosting owner confirmation'; Passed=(Get-GitHubHostingRequiredBoolean -InputObject (Get-GitHubHostingPropertyValue $Configuration 'metadata') -Name 'ownerConfirmed'); Details='GitHub Releases metadata endpoint is owner-confirmed.' },
        [pscustomobject]@{ Name='GitHub CLI available'; Passed=[bool](Get-GitHubHostingPropertyValue $GitHubState 'CliAvailable'); Details='Read-only gh checks only.' },
        [pscustomobject]@{ Name='GitHub authentication'; Passed=[bool](Get-GitHubHostingPropertyValue $GitHubState 'Authenticated'); Details='github.com authentication required.' },
        [pscustomobject]@{ Name='GitHub query completeness'; Passed=[bool](Get-GitHubHostingPropertyValue $GitHubState 'QueriesSucceeded'); Details='Every read-only identity, commit, tag, release, and asset query must succeed.' },
        [pscustomobject]@{ Name='GitHub repository identity'; Passed=[bool](Get-GitHubHostingPropertyValue $GitHubState 'RepositoryMatches'); Details=[string](Get-GitHubHostingPropertyValue $Configuration 'repository') },
        [pscustomobject]@{ Name='GitHub repository visibility'; Passed=[bool](Get-GitHubHostingPropertyValue $GitHubState 'PublicRepository'); Details='Public repository required for anonymous updater downloads.' },
        [pscustomobject]@{ Name='GitHub viewer permission'; Passed=[bool](Get-GitHubHostingPropertyValue $GitHubState 'PermissionSufficient'); Details='WRITE, MAINTAIN, or ADMIN is required.' },
        [pscustomobject]@{ Name='HEAD exists in target repository'; Passed=[bool](Get-GitHubHostingPropertyValue $GitHubState 'HeadCommitExists'); Details='Current commit must already exist in the configured GitHub repository.' },
        [pscustomobject]@{ Name='Target tag is unused'; Passed=[bool](Get-GitHubHostingPropertyValue $GitHubState 'TargetTagStateSatisfied'); Details='Preflight requires no matching remote tag.' },
        [pscustomobject]@{ Name='Target release is unused'; Passed=[bool](Get-GitHubHostingPropertyValue $GitHubState 'TargetReleaseStateSatisfied'); Details='Preflight requires no matching draft or published release.' },
        [pscustomobject]@{ Name='Versioned artifact names are unused'; Passed=[bool](Get-GitHubHostingPropertyValue $GitHubState 'AssetNameStateSatisfied'); Details='No existing release may contain the planned versioned artifact or signature filenames.' },
        [pscustomobject]@{ Name='Git worktree clean'; Passed=(-not [bool](Get-GitHubHostingPropertyValue $GitState 'DirtyWorktree')); Details='Signed release inputs must bind to a clean commit.' },
        [pscustomobject]@{ Name='Local origin repository'; Passed=[bool](Get-GitHubHostingPropertyValue $GitState 'OriginMatches'); Details='origin must resolve exactly to ylc77/desktop-pet.' },
        [pscustomobject]@{ Name='Complete release bundle validation'; Passed=$completeBundleValid; Details='Schema, identity, transition, filenames, hashes, endpoint, signature metadata, and cryptographic proof must all match.' },
        [pscustomobject]@{ Name='Manifest version'; Passed=([string](Get-GitHubHostingPropertyValue $manifest 'version') -eq $Version); Details="expected=$Version" },
        [pscustomobject]@{ Name='Manifest current version'; Passed=([string](Get-GitHubHostingPropertyValue $manifest 'currentVersion') -ceq $CurrentVersion); Details="expected=$CurrentVersion" },
        [pscustomobject]@{ Name='Manifest commit'; Passed=([string](Get-GitHubHostingPropertyValue $manifest 'gitCommit') -eq [string](Get-GitHubHostingPropertyValue $GitState 'Commit')); Details='Must match current HEAD.' },
        [pscustomobject]@{ Name='Manifest clean state'; Passed=(-not $manifestDirty); Details='dirtyWorktree must be false.' },
        [pscustomobject]@{ Name='Manifest cryptographic result'; Passed=$manifestCryptographic; Details='The prepared release manifest must record successful verification.' },
        [pscustomobject]@{ Name='Artifact filename'; Passed=([string](Get-GitHubHostingPropertyValue $manifest 'artifactFile') -ceq $artifactName); Details=$artifactName },
        [pscustomobject]@{ Name='Signature filename'; Passed=([string](Get-GitHubHostingPropertyValue $manifest 'signatureFile') -ceq $signatureName); Details=$signatureName },
        [pscustomobject]@{ Name='Artifact size'; Passed=([long](Get-GitHubHostingPropertyValue $manifest 'artifactSizeBytes') -eq $artifactSize); Details="bytes=$artifactSize" },
        [pscustomobject]@{ Name='Artifact SHA-256'; Passed=([string](Get-GitHubHostingPropertyValue $manifest 'artifactSha256') -ceq $artifactHash); Details='Local bytes match manifest.' },
        [pscustomobject]@{ Name='Signature SHA-256'; Passed=([string](Get-GitHubHostingPropertyValue $manifest 'signatureSha256') -ceq $signatureHash); Details='Detached signature file matches manifest.' },
        [pscustomobject]@{ Name='Metadata SHA-256'; Passed=([string](Get-GitHubHostingPropertyValue $manifest 'latestJsonSha256') -ceq $latestHash); Details='latest.json matches manifest.' },
        [pscustomobject]@{ Name='SHA256SUMS binding'; Passed=$checksumValid; Details='Checksums bind the exact artifact, detached signature, and latest.json.' },
        [pscustomobject]@{ Name='Public-key fingerprint'; Passed=([string](Get-GitHubHostingPropertyValue $manifest 'publicKeyFingerprint') -ceq $fingerprint); Details=$fingerprint },
        [pscustomobject]@{ Name='Immutable asset URL'; Passed=([string](Get-GitHubHostingPropertyValue $manifest 'downloadUrl') -ceq $downloadUrl -and [string]$latestEntry.url -ceq $downloadUrl); Details=$downloadUrl },
        [pscustomobject]@{ Name='Stable metadata endpoint'; Passed=([string](Get-GitHubHostingPropertyValue $manifest 'endpoint') -ceq $endpoint); Details=$endpoint },
        [pscustomobject]@{ Name='Detached signature metadata'; Passed=([string]$latestEntry.signature -ceq $signatureText); Details='latest.json signature matches the detached .sig text.' },
        [pscustomobject]@{ Name='Local cryptographic verification'; Passed=$signatureVerified; Details='Artifact must verify with the selected public key.' }
    )
    $allChecksPassed = @($checks | Where-Object { -not $_.Passed }).Count -eq 0
    $tag = Get-GitHubUpdaterReleaseTag -Configuration $Configuration -Version $Version
    return [pscustomobject]@{
        Mode = 'PreviewOnly'
        GateSatisfied = $allChecksPassed
        RemoteMutationPerformed = $false
        Repository = [string](Get-GitHubHostingPropertyValue $Configuration 'repository')
        OperatorLogin = [string](Get-GitHubHostingPropertyValue $GitHubState 'OperatorLogin')
        Version = $Version
        Tag = $tag
        Release = [pscustomobject]@{
            Draft = Get-GitHubHostingRequiredBoolean -InputObject (Get-GitHubHostingPropertyValue $Configuration 'release') -Name 'draft'
            Prerelease = Get-GitHubHostingRequiredBoolean -InputObject (Get-GitHubHostingPropertyValue $Configuration 'release') -Name 'prerelease'
            Assets = @($artifactName,$signatureName,[System.IO.Path]::GetFileName($LatestJsonPath),[System.IO.Path]::GetFileName($ManifestPath),[System.IO.Path]::GetFileName($ChecksumPath))
            ImmutableArtifactUrl = $downloadUrl
        }
        Metadata = [pscustomobject]@{
            StableEndpoint = $endpoint
            VersionedEndpoint = $versionedMetadataUrl
            PublishOrder = 'Create the versioned draft, upload and verify every asset, then publish it as the non-prerelease GitHub latest release so the stable latest.json endpoint advances.'
        }
        RemoteVerification = [pscustomobject]@{
            AuthenticatedDraftDownload = 'Use verify-github-release-assets.ps1 after the draft assets exist.'
            ExpectedArtifactSha256 = $artifactHash
            ExpectedSignatureSha256 = $signatureHash
            ExpectedPublicKeyFingerprint = $fingerprint
            RequireAnonymousDownloadAfterPublish = $true
        }
        Checks = @($checks)
        ProhibitedRoutes = @('public installer aliases in updater metadata','unversioned installer asset URLs')
    }
}
