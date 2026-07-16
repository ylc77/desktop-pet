[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$CurrentVersion,
    [Parameter(Mandatory)][string]$ArtifactPath,
    [Parameter(Mandatory)][string]$SignaturePath,
    [Parameter(Mandatory)][string]$PublicKeyPath,
    [Parameter(Mandatory)][string]$LatestJsonPath,
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$ChecksumPath,
    [string]$HostingConfigurationPath
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. ([System.IO.Path]::Combine($PSScriptRoot, 'common.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'github-release-common.ps1'))

if ([string]::IsNullOrWhiteSpace($HostingConfigurationPath)) {
    $HostingConfigurationPath = [System.IO.Path]::Combine($script:UpdaterRepositoryRoot, 'config', 'updater.github-releases.json')
}
$configuration = Read-GitHubUpdaterHostingConfiguration -LiteralPath (Resolve-UpdaterPath -Path $HostingConfigurationPath -BaseDirectory $InvocationDirectory)
if (-not (Get-GitHubHostingRequiredBoolean -InputObject $configuration -Name 'enabled') -or
    -not (Get-GitHubHostingRequiredBoolean -InputObject (Get-GitHubHostingPropertyValue $configuration 'metadata') -Name 'ownerConfirmed')) {
    throw 'GitHub updater hosting and metadata must be explicitly enabled before remote verification.'
}
$artifact = Resolve-UpdaterPath -Path $ArtifactPath -BaseDirectory $InvocationDirectory
$signature = Resolve-UpdaterPath -Path $SignaturePath -BaseDirectory $InvocationDirectory
$publicKey = Resolve-UpdaterPath -Path $PublicKeyPath -BaseDirectory $InvocationDirectory
$latestJson = Resolve-UpdaterPath -Path $LatestJsonPath -BaseDirectory $InvocationDirectory
$manifestPathValue = Resolve-UpdaterPath -Path $ManifestPath -BaseDirectory $InvocationDirectory
$checksum = Resolve-UpdaterPath -Path $ChecksumPath -BaseDirectory $InvocationDirectory
foreach ($path in @($artifact,$signature,$publicKey,$latestJson,$manifestPathValue,$checksum)) {
    if (-not [System.IO.File]::Exists($path)) { throw 'A required remote verification input file does not exist.' }
}
[void](Get-SemVerParts -Version $Version)
[void](Get-SemVerParts -Version $CurrentVersion)
$localBundle = Assert-GitHubUpdaterReleaseBundle -Configuration $configuration -Version $Version -CurrentVersion $CurrentVersion `
    -ArtifactPath $artifact -SignaturePath $signature -PublicKeyPath $publicKey -LatestJsonPath $latestJson `
    -ManifestPath $manifestPathValue -ChecksumPath $checksum
$repository = [string](Get-GitHubHostingPropertyValue $configuration 'repository')
$tag = Get-GitHubUpdaterReleaseTag -Configuration $configuration -Version $Version
$plannedAssetNames = @(
    [System.IO.Path]::GetFileName($artifact), [System.IO.Path]::GetFileName($signature),
    [System.IO.Path]::GetFileName($latestJson), [System.IO.Path]::GetFileName($manifestPathValue), [System.IO.Path]::GetFileName($checksum)
)
$repositoryState = Get-GitHubUpdaterRepositoryState -Repository $repository -HeadCommit $localBundle.ManifestCommit `
    -Tag $tag -AssetNames $plannedAssetNames -ReleaseExpectation Draft
if (-not $repositoryState.Authenticated -or -not $repositoryState.QueriesSucceeded -or
    -not $repositoryState.RepositoryMatches -or -not $repositoryState.PublicRepository -or
    -not $repositoryState.PermissionSufficient -or -not $repositoryState.HeadCommitExists -or
    -not $repositoryState.TargetTagStateSatisfied -or -not $repositoryState.TargetReleaseStateSatisfied -or
    -not $repositoryState.AssetNameStateSatisfied) {
    throw 'GitHub repository identity, permission, commit, release, tag, or asset verification failed.'
}
$gh = Get-Command gh.exe -ErrorAction SilentlyContinue
if ($null -eq $gh) { $gh = Get-Command gh -ErrorAction Stop }
$temporaryDirectory = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'qijiang-github-redownload-' + [Guid]::NewGuid().ToString('N'))
$verificationResult = $null
try {
    [void][System.IO.Directory]::CreateDirectory($temporaryDirectory)
    $downloadArguments = Get-GitHubUpdaterReleaseDownloadArguments -Repository $repository -Tag $tag `
        -AssetNames $plannedAssetNames -DestinationDirectory $temporaryDirectory
    $downloadExit = Invoke-UpdaterToolProcess -FilePath $gh.Source -ArgumentList $downloadArguments -TimeoutSeconds 300
    if ($downloadExit -ne 0) { throw 'Authenticated GitHub Release asset download failed.' }
    $downloadedArtifact = [System.IO.Path]::Combine($temporaryDirectory, [System.IO.Path]::GetFileName($artifact))
    $downloadedSignature = [System.IO.Path]::Combine($temporaryDirectory, [System.IO.Path]::GetFileName($signature))
    $downloadedLatest = [System.IO.Path]::Combine($temporaryDirectory, [System.IO.Path]::GetFileName($latestJson))
    $downloadedManifest = [System.IO.Path]::Combine($temporaryDirectory, [System.IO.Path]::GetFileName($manifestPathValue))
    $downloadedChecksum = [System.IO.Path]::Combine($temporaryDirectory, [System.IO.Path]::GetFileName($checksum))
    foreach ($downloadedPath in @($downloadedArtifact,$downloadedSignature,$downloadedLatest,$downloadedManifest,$downloadedChecksum)) {
        if (-not [System.IO.File]::Exists($downloadedPath)) { throw 'GitHub Release download did not return every exact planned asset.' }
    }
    $remoteBundle = Assert-GitHubUpdaterReleaseBundle -Configuration $configuration -Version $Version -CurrentVersion $CurrentVersion `
        -ArtifactPath $downloadedArtifact -SignaturePath $downloadedSignature -PublicKeyPath $publicKey `
        -LatestJsonPath $downloadedLatest -ManifestPath $downloadedManifest -ChecksumPath $downloadedChecksum
    if ($remoteBundle.ManifestCommit -cne $localBundle.ManifestCommit -or
        $remoteBundle.ArtifactSha256 -cne $localBundle.ArtifactSha256 -or
        $remoteBundle.SignatureSha256 -cne $localBundle.SignatureSha256 -or
        $remoteBundle.LatestJsonSha256 -cne $localBundle.LatestJsonSha256 -or
        (Get-Sha256Hex -LiteralPath $downloadedManifest) -cne (Get-Sha256Hex -LiteralPath $manifestPathValue) -or
        (Get-Sha256Hex -LiteralPath $downloadedChecksum) -cne (Get-Sha256Hex -LiteralPath $checksum)) {
        throw 'Remote GitHub Release bundle does not exactly match the validated local release bundle.'
    }
    $verificationResult = [pscustomobject]@{
        Verified=$true
        Repository=$repository
        Tag=$tag
        OperatorLogin=[string]$repositoryState.OperatorLogin
        Artifact=[System.IO.Path]::GetFileName($downloadedArtifact)
        ArtifactSha256=$remoteBundle.ArtifactSha256
        PublicKeyFingerprint=$remoteBundle.PublicKeyFingerprint
        ManifestCommit=$remoteBundle.ManifestCommit
        TemporaryFilesRemoved=$false
        RemoteMutationPerformed=$false
    }
} finally {
    if ([System.IO.Directory]::Exists($temporaryDirectory)) {
        try { [System.IO.Directory]::Delete($temporaryDirectory, $true) }
        catch { throw 'Remote verification temporary-file cleanup failed.' }
    }
}
if ($null -eq $verificationResult) { throw 'Remote GitHub Release verification did not produce a result.' }
$verificationResult.TemporaryFilesRemoved = $true
return $verificationResult
