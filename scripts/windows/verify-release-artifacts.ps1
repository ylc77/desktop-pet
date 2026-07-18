[CmdletBinding()]
param(
    [string]$ReleaseDirectory,
    [string]$UpdaterPublicKeyPath,
    [switch]$RequireUpdater
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
if ([string]::IsNullOrWhiteSpace($ReleaseDirectory)) { $ReleaseDirectory = [System.IO.Path]::Combine($script:RepositoryRoot, 'release') }
$release = Resolve-CallerPath -Path $ReleaseDirectory -BaseDirectory $InvocationDirectory
if (-not [string]::IsNullOrWhiteSpace($UpdaterPublicKeyPath)) { $UpdaterPublicKeyPath = Resolve-CallerPath -Path $UpdaterPublicKeyPath -BaseDirectory $InvocationDirectory }
if (-not [System.IO.Directory]::Exists($release)) { throw "Release directory not found: $release" }
$manifestPath = Join-Path $release 'release-manifest.json'
$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
$versionContext = Resolve-DeskPetVersionContext -RepositoryRoot $script:RepositoryRoot -ReleaseDirectory $release -InstallerPath ([System.IO.Path]::Combine($release, [string]$manifest.versionedInstallerFile)) -ExplicitExpectedVersion ([string]$manifest.version)
Assert-DeskPetVersionContext -VersionContext $versionContext
$installer = Get-Item -LiteralPath (Join-Path $release $manifest.versionedInstallerFile)
$publicInstaller = Get-Item -LiteralPath (Join-Path $release $manifest.publicInstallerFile)
$hash = Get-FileHash -LiteralPath $installer.FullName -Algorithm SHA256
$publicHash = Get-FileHash -LiteralPath $publicInstaller.FullName -Algorithm SHA256
$signature = Get-AuthenticodeSignature -FilePath $publicInstaller.FullName
$checksumLines = @(Get-Content -Encoding UTF8 -LiteralPath (Join-Path $release 'SHA256SUMS.txt'))
$sensitiveHits = @(Get-ChildItem -LiteralPath $release -File -Recurse | Where-Object Extension -in @('.json','.txt') | Select-String -Pattern 'C:\\Users\\|F:\\STAGE|\\\\[^\\]+\\[^\\]+' -ErrorAction SilentlyContinue)
$updater = Get-DeskPetUpdaterReadiness -RepositoryRoot $script:RepositoryRoot -ReleaseDirectory $release -ExpectedVersion $versionContext.ExpectedVersion
$publicKeyHash = if (-not [string]::IsNullOrWhiteSpace($UpdaterPublicKeyPath) -and [System.IO.File]::Exists($UpdaterPublicKeyPath)) { Get-UpdaterPublicKeyFingerprint -PublicKeyPath $UpdaterPublicKeyPath } else { $null }
$publicKeyVerified = -not [string]::IsNullOrWhiteSpace($publicKeyHash) -and $publicKeyHash -eq $updater.PublicKeyFingerprint
$cryptographicSignatureAttempted = $false
$cryptographicSignatureVerified = $false
$cryptographicSignatureError = $null
if (-not [string]::IsNullOrWhiteSpace($UpdaterPublicKeyPath) -and [System.IO.File]::Exists($UpdaterPublicKeyPath) -and
    -not [string]::IsNullOrWhiteSpace([string]$updater.ArtifactPath) -and [System.IO.File]::Exists([string]$updater.ArtifactPath) -and
    -not [string]::IsNullOrWhiteSpace([string]$updater.SignaturePath) -and [System.IO.File]::Exists([string]$updater.SignaturePath)) {
    $cryptographicSignatureAttempted = $true
    try {
        $cryptographicSignatureVerified = Test-DeskPetUpdaterArtifactSignature -ArtifactPath $updater.ArtifactPath -SignaturePath $updater.SignaturePath -PublicKeyPath $UpdaterPublicKeyPath
    } catch {
        $cryptographicSignatureError = $_.Exception.GetType().Name
    }
}
$cryptographicSignatureRequired = [bool]$RequireUpdater -or -not [string]::IsNullOrWhiteSpace($UpdaterPublicKeyPath)
$updaterPass = if ($RequireUpdater) {
    $updater.Ready -and $publicKeyVerified -and $cryptographicSignatureVerified
} elseif ($cryptographicSignatureRequired) {
    $updater.State -eq 'READY' -and $publicKeyVerified -and $cryptographicSignatureVerified
} else { $updater.State -in @('NOT_CONFIGURED', 'READY') }
$baseBundle = Get-ObjectPropertyValue $script:TauriConfig 'bundle'
$basePlugins = Get-ObjectPropertyValue $script:TauriConfig 'plugins'
$baseUpdaterPlugin = Get-ObjectPropertyValue $basePlugins 'updater'
$baseUpdaterEndpoints = @(Get-ObjectPropertyValue $baseUpdaterPlugin 'endpoints')
$baseUpdaterWindows = Get-ObjectPropertyValue $baseUpdaterPlugin 'windows'
$baseUpdaterDisabled = -not [bool](Get-ObjectPropertyValue $baseBundle 'createUpdaterArtifacts') -and
    $null -ne $baseUpdaterPlugin -and
    [string]::IsNullOrWhiteSpace([string](Get-ObjectPropertyValue $baseUpdaterPlugin 'pubkey')) -and
    $baseUpdaterEndpoints.Count -eq 0 -and
    [string](Get-ObjectPropertyValue $baseUpdaterWindows 'installMode') -eq 'passive'
$manifestDirtyValue = Get-ObjectPropertyValue $manifest 'dirtyWorktree'
$checks = @(
    [pscustomobject]@{ Check = 'Installer hash matches manifest'; Passed = $hash.Hash -eq $manifest.sha256; Details = $hash.Hash }
    [pscustomobject]@{ Check = 'Public installer hash matches versioned installer'; Passed = $publicHash.Hash -eq $hash.Hash -and $publicHash.Hash -eq $manifest.publicInstallerSha256; Details = $publicHash.Hash }
    [pscustomobject]@{ Check = 'Checksum file contains public installer'; Passed = $checksumLines -contains "$($publicHash.Hash)  $($publicInstaller.Name)"; Details = $checksumLines -join '; ' }
    [pscustomobject]@{ Check = 'Checksum file contains versioned installer'; Passed = $checksumLines -contains "$($hash.Hash)  $($installer.Name)"; Details = $checksumLines -join '; ' }
    [pscustomobject]@{ Check = 'Manifest records expected public filename'; Passed = [string]$manifest.publicInstallerFile -eq $script:PublicInstallerName; Details = [string]$manifest.publicInstallerFile }
    [pscustomobject]@{ Check = 'Manifest records expected executable filename'; Passed = [string]$manifest.mainExecutableFile -eq $script:ExecutableName; Details = [string]$manifest.mainExecutableFile }
    [pscustomobject]@{ Check = 'Manifest commit matches HEAD'; Passed = $manifest.gitCommit -eq (& git rev-parse HEAD).Trim(); Details = [string]$manifest.gitCommit }
    [pscustomobject]@{ Check = 'Manifest records clean build'; Passed = $null -ne $manifestDirtyValue -and -not [bool]$manifestDirtyValue; Details = "dirty=$(if($null -eq $manifestDirtyValue){'missing'}else{[bool]$manifestDirtyValue})" }
    [pscustomobject]@{ Check = 'Character schema remains version 1'; Passed = [int]$manifest.characterSchemaVersion -eq 1; Details = [string]$manifest.characterSchemaVersion }
    [pscustomobject]@{ Check = 'Release metadata has no local paths'; Passed = $sensitiveHits.Count -eq 0; Details = "hits=$($sensitiveHits.Count)" }
    [pscustomobject]@{ Check = 'Updater release readiness'; Passed = $updaterPass; Details = "state=$($updater.State); required=$([bool]$RequireUpdater)" }
    [pscustomobject]@{ Check = 'Updater build overlay available'; Passed = $updater.BuildOverlayEnabled; Details = 'tauri.updater.conf.json createUpdaterArtifacts=true' }
    [pscustomobject]@{ Check = 'Base build has a safe unconfigured updater object'; Passed = $baseUpdaterDisabled; Details = 'base createUpdaterArtifacts=false; pubkey empty; endpoints empty; installMode=passive' }
)
if ($updater.State -ne 'NOT_CONFIGURED') {
    $checks += @($updater.Checks | ForEach-Object {
        [pscustomobject]@{ Check = $_.Name; Passed = [bool]$_.Passed; Details = [string]$_.Details }
    })
}
if ($cryptographicSignatureRequired) {
    $checks += [pscustomobject]@{ Check = 'Updater production public key'; Passed = $publicKeyVerified; Details = $(if($publicKeyVerified){"fingerprint=$publicKeyHash"}else{'missing, unreadable, or fingerprint mismatch'}) }
    $checks += [pscustomobject]@{ Check = 'Updater cryptographic artifact signature'; Passed = $cryptographicSignatureVerified; Details = "attempted=$cryptographicSignatureAttempted; verified=$cryptographicSignatureVerified; error=$(if($cryptographicSignatureError){$cryptographicSignatureError}else{'none'})" }
}
$checks | Format-Table -AutoSize
[pscustomobject]@{
    VersionedInstaller = $installer.Name
    PublicInstaller = $publicInstaller.Name
    SizeBytes = $publicInstaller.Length
    SHA256 = $publicHash.Hash
    SignatureStatus = [string]$signature.Status
    UpdaterStatus = $updater.State
    UpdaterRequired = [bool]$RequireUpdater
    ChecksPassed = @($checks | Where-Object Passed).Count
    ChecksFailed = @($checks | Where-Object { -not $_.Passed }).Count
} | ConvertTo-Json -Depth 4
if (@($checks | Where-Object { -not $_.Passed }).Count) { exit 2 }
