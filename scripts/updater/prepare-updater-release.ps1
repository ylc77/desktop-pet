[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$CurrentVersion,
    [Parameter(Mandatory)][string]$ArtifactPath,
    [Parameter(Mandatory)][string]$SignaturePath,
    [Parameter(Mandatory)][string]$PublicKeyPath,
    [Parameter(Mandatory)][string]$DownloadUrl,
    [Parameter(Mandatory)][string]$Endpoint,
    [Parameter(Mandatory)][string]$Identifier,
    [string]$ReleaseDirectory,
    [string]$Platform = 'windows-x86_64',
    [string]$ApplicationName = (-join @([char]0x4E03,[char]0x9171,[char]0x684C,[char]0x5BA0)),
    [AllowEmptyString()][string]$Notes = '',
    [string]$PublishedAtUtc = ([DateTimeOffset]::UtcNow.ToString('o'))
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. ([System.IO.Path]::Combine($PSScriptRoot, 'common.ps1'))

if ([string]::IsNullOrWhiteSpace($ReleaseDirectory)) {
    $ReleaseDirectory = [System.IO.Path]::Combine($script:UpdaterRepositoryRoot, 'release')
}
$releaseRoot = Resolve-UpdaterPath -Path $ReleaseDirectory -BaseDirectory $InvocationDirectory
$artifact = Resolve-UpdaterPath -Path $ArtifactPath -BaseDirectory $InvocationDirectory
$signatureFile = Resolve-UpdaterPath -Path $SignaturePath -BaseDirectory $InvocationDirectory
$publicKey = Resolve-UpdaterPath -Path $PublicKeyPath -BaseDirectory $InvocationDirectory
if (-not [System.IO.File]::Exists($artifact)) { throw "Updater artifact not found: $([System.IO.Path]::GetFileName($artifact))" }
if (-not [System.IO.File]::Exists($publicKey)) { throw 'Updater public key file does not exist.' }
if ([string]::IsNullOrWhiteSpace($Identifier) -or $Identifier -notmatch '^[A-Za-z0-9.-]+$') { throw 'Application identifier is invalid.' }
[void](Get-SemVerParts -Version $Version)
[void](Get-SemVerParts -Version $CurrentVersion)
Assert-UpdaterVersionIncrease -CurrentVersion $CurrentVersion -Version $Version
$download = Assert-UpdaterArtifactBinding -ArtifactPath $artifact -Version $Version -DownloadUrl $DownloadUrl
$endpointUrl = Assert-UpdaterHttpsUrl -Url $Endpoint
$endpointUri = New-Object Uri($endpointUrl)
if (-not $endpointUri.AbsolutePath.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Updater endpoint must identify an HTTPS JSON metadata document.'
}
Assert-UpdaterSignatureBinding -ArtifactPath $artifact -SignaturePath $signatureFile
$signature = Get-UpdaterSignatureText -SignaturePath $signatureFile
$publicKeyFingerprint = Get-UpdaterPublicKeyFingerprint -LiteralPath $publicKey
$artifactSize = (Get-Item -LiteralPath $artifact).Length
$gitState = Get-UpdaterGitState

$updaterRoot = [System.IO.Path]::Combine($releaseRoot, 'updater')
$versionDirectory = [System.IO.Path]::Combine($updaterRoot, $Version)
$topLevelLatestPath = [System.IO.Path]::Combine($updaterRoot, 'latest.json')
if ([System.IO.Directory]::Exists($versionDirectory) -or [System.IO.File]::Exists($versionDirectory)) {
    throw "Refusing to overwrite an existing updater version directory: $Version"
}
if ([System.IO.File]::Exists($topLevelLatestPath)) {
    $existingJson = Get-FileTextWithoutBom -LiteralPath $topLevelLatestPath
    try { $existingLatest = $existingJson | ConvertFrom-Json } catch { throw 'Existing release/updater/latest.json is invalid; refusing to overwrite it.' }
    $existingVersion = [string]$existingLatest.version
    [void](Get-SemVerParts -Version $existingVersion)
    if ((Compare-SemVer -Left $Version -Right $existingVersion) -le 0) {
        throw "Refusing to replace latest.json with a non-newer version: existing=$existingVersion; candidate=$Version"
    }
    $previousManifestPath = [System.IO.Path]::Combine($updaterRoot, $existingVersion, 'updater-release-manifest.json')
    if (-not [System.IO.File]::Exists($previousManifestPath)) {
        throw 'Existing latest.json has no versioned updater manifest; refusing an unverifiable security transition.'
    }
    $previousManifestText = Get-FileTextWithoutBom -LiteralPath $previousManifestPath
    Assert-NoUpdaterSensitiveMetadata -Text $previousManifestText
    try { $previousManifest = $previousManifestText | ConvertFrom-Json } catch { throw 'Existing updater release manifest is invalid.' }
    if ([string]$previousManifest.identifier -ne $Identifier) { throw 'Updater identifier continuity check failed.' }
    if ([string]$previousManifest.publicKeyFingerprint -ne $publicKeyFingerprint) { throw 'Updater public-key fingerprint continuity check failed.' }
    if ([string]$previousManifest.endpoint -ne $endpointUrl) { throw 'Updater endpoint continuity check failed.' }
    if ([string]$previousManifest.installMode -ne 'passive') { throw 'Updater install-mode continuity check failed.' }
    if ([string]$previousManifest.platform -ne $Platform) { throw 'Updater platform continuity check failed.' }
}

$plan = [pscustomobject]@{
    Mode = $(if ($WhatIfPreference) { 'PreviewOnly' } else { 'PrepareRequested' })
    Version = $Version
    VersionDirectory = [System.IO.Path]::Combine('release', 'updater', $Version)
    LatestJson = [System.IO.Path]::Combine('release', 'updater', 'latest.json')
    Artifact = [System.IO.Path]::GetFileName($artifact)
    Identifier = $Identifier
    PublicKeyFingerprint = $publicKeyFingerprint
    Endpoint = $endpointUrl
    InstallMode = 'passive'
    GitCommit = $gitState.Commit
    DirtyWorktree = $gitState.DirtyWorktree
    CryptographicSignatureVerification = 'Required after confirmation; skipped during WhatIf to avoid compiler output writes'
}
if (-not $PSCmdlet.ShouldProcess([System.IO.Path]::Combine('release', 'updater', $Version), 'Prepare immutable updater release and advance latest.json')) {
    return $plan
}
if (-not (Test-UpdaterArtifactSignature -ArtifactPath $artifact -SignaturePath $signatureFile -PublicKeyPath $publicKey)) {
    throw 'Updater artifact signature verification failed.'
}

$artifactName = [System.IO.Path]::GetFileName($artifact)
$signatureName = [System.IO.Path]::GetFileName($signatureFile)
$document = New-UpdaterLatestDocument -Version $Version -CurrentVersion $CurrentVersion -DownloadUrl $download `
    -Signature $signature -Platform $Platform -PublishedAtUtc $PublishedAtUtc -ArtifactSizeBytes $artifactSize -Notes $Notes
$createdVersionDirectory = $false
try {
    [void][System.IO.Directory]::CreateDirectory($versionDirectory)
    $createdVersionDirectory = $true
    $artifactDestination = [System.IO.Path]::Combine($versionDirectory, $artifactName)
    $signatureDestination = [System.IO.Path]::Combine($versionDirectory, $signatureName)
    $latestDestination = [System.IO.Path]::Combine($versionDirectory, 'latest.json')
    [System.IO.File]::Copy($artifact, $artifactDestination, $false)
    [System.IO.File]::Copy($signatureFile, $signatureDestination, $false)
    Write-Utf8NoBomJson -InputObject $document -LiteralPath $latestDestination
    [void](Test-UpdaterLatestDocument -LatestJsonPath $latestDestination -CurrentVersion $CurrentVersion -ExpectedVersion $Version -ExpectedPlatform $Platform -ExpectedArtifactSizeBytes $artifactSize)

    $manifest = [ordered]@{
        schemaVersion = 1
        applicationName = $ApplicationName
        identifier = $Identifier
        version = $Version
        currentVersion = $CurrentVersion
        platform = $Platform
        artifactFile = $artifactName
        signatureFile = $signatureName
        latestJsonFile = 'latest.json'
        artifactSizeBytes = $artifactSize
        artifactSha256 = Get-Sha256Hex -LiteralPath $artifactDestination
        signatureSha256 = Get-Sha256Hex -LiteralPath $signatureDestination
        latestJsonSha256 = Get-Sha256Hex -LiteralPath $latestDestination
        publicKeyFingerprint = $publicKeyFingerprint
        downloadUrl = $download
        endpoint = $endpointUrl
        installMode = 'passive'
        preparedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        gitCommit = $gitState.Commit
        dirtyWorktree = $gitState.DirtyWorktree
        cryptographicSignatureVerified = $true
    }
    $manifestPath = [System.IO.Path]::Combine($versionDirectory, 'updater-release-manifest.json')
    Write-Utf8NoBomJson -InputObject $manifest -LiteralPath $manifestPath
    $checksumLines = @(
        "$($manifest.artifactSha256)  $artifactName",
        "$($manifest.signatureSha256)  $signatureName",
        "$($manifest.latestJsonSha256)  latest.json"
    )
    [System.IO.File]::WriteAllLines([System.IO.Path]::Combine($versionDirectory, 'SHA256SUMS.txt'), $checksumLines, $script:Utf8NoBom)

    [void][System.IO.Directory]::CreateDirectory($updaterRoot)
    $temporaryLatest = [System.IO.Path]::Combine($updaterRoot, '.latest-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::Copy($latestDestination, $temporaryLatest, $false)
        [System.IO.File]::Copy($temporaryLatest, $topLevelLatestPath, $true)
    } finally {
        if ([System.IO.File]::Exists($temporaryLatest)) { [System.IO.File]::Delete($temporaryLatest) }
    }
} catch {
    if ($createdVersionDirectory -and [System.IO.Directory]::Exists($versionDirectory)) {
        [System.IO.Directory]::Delete($versionDirectory, $true)
    }
    throw
}

[pscustomobject]@{
    Prepared = $true
    Version = $Version
    VersionDirectory = [System.IO.Path]::Combine('release', 'updater', $Version)
    LatestJson = [System.IO.Path]::Combine('release', 'updater', 'latest.json')
    Artifact = $artifactName
    Identifier = $Identifier
    PublicKeyFingerprint = $publicKeyFingerprint
    Endpoint = $endpointUrl
    InstallMode = 'passive'
    CryptographicSignatureVerified = $true
}
