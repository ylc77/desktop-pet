[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$EndpointBaseUrl,
    [Parameter(Mandatory)][Alias('KeyPath')][string]$PrivateKeyPath,
    [string]$PublicKeyPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidatePattern('^[a-z0-9-]+$')][string]$Channel = 'beta',
    [switch]$Execute
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. ([System.IO.Path]::Combine($PSScriptRoot, 'common.ps1'))

[void](Get-SemVerParts -Version $Version)
$privateKey = Assert-UpdaterPrivateKeyPath -KeyPath $PrivateKeyPath
if ([string]::IsNullOrWhiteSpace($PublicKeyPath)) { $PublicKeyPath = $privateKey + '.pub' }
$publicKey = Resolve-UpdaterPath -Path $PublicKeyPath -BaseDirectory $InvocationDirectory
$output = Resolve-UpdaterPath -Path $OutputDirectory -BaseDirectory $InvocationDirectory
$baseUrl = Assert-UpdaterHttpsUrl -Url $EndpointBaseUrl
$baseUri = New-Object Uri($baseUrl)
$endpointUrl = if ($baseUri.AbsolutePath.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) {
    $baseUri.AbsoluteUri
} else {
    $directoryUrl = $baseUri.AbsoluteUri
    if (-not $directoryUrl.EndsWith('/')) { $directoryUrl += '/' }
    (New-Object Uri((New-Object Uri($directoryUrl)), 'latest.json')).AbsoluteUri
}
$tauriConfigPath = [System.IO.Path]::Combine($script:UpdaterRepositoryRoot, 'src-tauri', 'tauri.conf.json')
if (-not [System.IO.File]::Exists($tauriConfigPath)) { throw 'Tauri configuration does not exist.' }
$tauriConfig = Get-Content -LiteralPath $tauriConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$configuredVersion = [string]$tauriConfig.version
if ($configuredVersion -ne $Version) { throw "Signed build version mismatch: requested=$Version; tauri=$configuredVersion" }
$gitState = Get-UpdaterGitState
$plan = [pscustomobject]@{
    Mode = $(if ($Execute -and -not $WhatIfPreference) { 'SignedBuildRequested' } else { 'PreviewOnly' })
    Version = $Version
    Channel = $Channel
    Endpoint = $endpointUrl
    InstallMode = 'passive'
    PrivateKeyPath = ConvertTo-UpdaterRedactedPath $privateKey
    PrivateKeyPresent = [System.IO.File]::Exists($privateKey)
    PublicKeyPath = ConvertTo-UpdaterRedactedPath $publicKey
    PublicKeyPresent = [System.IO.File]::Exists($publicKey)
    OutputDirectory = ConvertTo-UpdaterRedactedPath $output
    GitCommit = $gitState.Commit
    DirtyWorktree = $gitState.DirtyWorktree
    SigningPasswordSource = 'Interactive secure prompt; process environment only'
    RuntimeConfiguration = 'Injected into the build process from the same endpoint, public key, and channel as the Tauri overlay'
    Upload = $false
    Install = $false
}

if (-not $Execute -or $WhatIfPreference) {
    Write-Host 'Preview only. No build was started, no output directory was created, and no signing environment variables were changed.'
    return $plan
}
if (-not [System.IO.File]::Exists($privateKey)) { throw 'Updater private key file does not exist.' }
if (-not [System.IO.File]::Exists($publicKey)) { throw 'Updater public key file does not exist.' }
if ($gitState.DirtyWorktree) { throw 'Refusing to create a signed updater build from a dirty Git worktree.' }
[void](Test-UpdaterKeyFiles -PrivateKeyPath $privateKey -PublicKeyPath $publicKey)
if ([System.IO.Directory]::Exists($output) -or [System.IO.File]::Exists($output)) {
    throw 'Refusing to overwrite an existing signed-build output path.'
}
$publicKeyText = Get-UpdaterPublicKeyText -LiteralPath $publicKey
$publicKeyFingerprint = Get-UpdaterPublicKeyTextFingerprint -PublicKeyText $publicKeyText
$privateKeyHash = Get-Sha256Hex -LiteralPath $privateKey
if (-not $PSCmdlet.ShouldProcess("version=$Version; channel=$Channel", 'Build signed updater artifacts')) { return $plan }

$tauriCli = [System.IO.Path]::Combine($script:UpdaterRepositoryRoot, 'node_modules', '.bin', 'tauri.cmd')
if (-not [System.IO.File]::Exists($tauriCli)) { throw 'The repository Tauri CLI is not installed.' }
$password = Read-Host 'Updater key password (input is hidden)' -AsSecureString
if ($password.Length -lt 16) { throw 'Updater key password must contain at least 16 characters.' }
$plainPassword = Convert-SecureStringToUpdaterPlainText -SecureString $password
$previousKey = [Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY', 'Process')
$previousPassword = [Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', 'Process')
$previousRuntimeEndpoint = [Environment]::GetEnvironmentVariable('QIJIANG_UPDATER_ENDPOINT', 'Process')
$previousRuntimePublicKey = [Environment]::GetEnvironmentVariable('QIJIANG_UPDATER_PUBLIC_KEY', 'Process')
$previousRuntimeChannel = [Environment]::GetEnvironmentVariable('QIJIANG_UPDATER_CHANNEL', 'Process')
$previousCargoTargetDirectory = [Environment]::GetEnvironmentVariable('CARGO_TARGET_DIR', 'Process')
$temporaryDirectory = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'qijiang-signed-build-' + [Guid]::NewGuid().ToString('N'))
$stagedOutput = $null
try {
    [void][System.IO.Directory]::CreateDirectory($temporaryDirectory)
    $isolatedTargetDirectory = [System.IO.Path]::Combine($temporaryDirectory, 'cargo-target')
    $outputParent = [System.IO.Path]::GetDirectoryName($output.TrimEnd('\', '/'))
    $outputName = [System.IO.Path]::GetFileName($output.TrimEnd('\', '/'))
    if ([string]::IsNullOrWhiteSpace($outputParent) -or [string]::IsNullOrWhiteSpace($outputName)) {
        throw 'Signed-build OutputDirectory must identify a child directory, not a filesystem root.'
    }
    [void][System.IO.Directory]::CreateDirectory($outputParent)
    $stagedOutput = [System.IO.Path]::Combine($outputParent, '.' + $outputName + '.staging-' + [Guid]::NewGuid().ToString('N'))
    $overlayPath = [System.IO.Path]::Combine($temporaryDirectory, 'tauri.updater.overlay.json')
    $publicKeySnapshot = [System.IO.Path]::Combine($temporaryDirectory, 'updater-public-key.snapshot')
    [void](Write-UpdaterPublicKeySnapshot -PublicKeyText $publicKeyText -LiteralPath $publicKeySnapshot)
    $overlay = [ordered]@{
        bundle = [ordered]@{ createUpdaterArtifacts=$true }
        plugins = [ordered]@{
            updater = [ordered]@{
                pubkey=$publicKeyText
                endpoints=@($endpointUrl)
                windows=[ordered]@{ installMode='passive' }
            }
        }
    }
    Write-Utf8NoBomJson -InputObject $overlay -LiteralPath $overlayPath
    [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY', $privateKey, 'Process')
    [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', $plainPassword, 'Process')
    [Environment]::SetEnvironmentVariable('QIJIANG_UPDATER_ENDPOINT', $endpointUrl, 'Process')
    [Environment]::SetEnvironmentVariable('QIJIANG_UPDATER_PUBLIC_KEY', $publicKeyText, 'Process')
    [Environment]::SetEnvironmentVariable('QIJIANG_UPDATER_CHANNEL', $Channel, 'Process')
    [Environment]::SetEnvironmentVariable('CARGO_TARGET_DIR', $isolatedTargetDirectory, 'Process')

    Push-Location $script:UpdaterRepositoryRoot
    try {
        & npm run validate
        if ($LASTEXITCODE -ne 0) { throw "Project validation failed with exit code $LASTEXITCODE." }
        & $tauriCli build --bundles nsis --config $overlayPath
        if ($LASTEXITCODE -ne 0) { throw "Signed Tauri build failed with exit code $LASTEXITCODE." }
    } finally {
        Pop-Location
    }

    $bundleDirectory = [System.IO.Path]::Combine($isolatedTargetDirectory, 'release', 'bundle', 'nsis')
    $installer = Get-ExactUpdaterInstallerArtifact -BundleDirectory $bundleDirectory `
        -ProductName ([string]$tauriConfig.productName) -Version $Version -Architecture 'x64'
    $signaturePath = $installer.FullName + '.sig'
    if (-not [System.IO.File]::Exists($signaturePath)) { throw 'Tauri build completed without the required updater signature artifact.' }
    [void](Get-UpdaterSignatureText -SignaturePath $signaturePath)
    [void][System.IO.Directory]::CreateDirectory($stagedOutput)
    $artifactDestination = [System.IO.Path]::Combine($stagedOutput, $installer.Name)
    $signatureDestination = [System.IO.Path]::Combine($stagedOutput, [System.IO.Path]::GetFileName($signaturePath))
    [System.IO.File]::Copy($installer.FullName, $artifactDestination, $false)
    [System.IO.File]::Copy($signaturePath, $signatureDestination, $false)
    if (-not (Test-UpdaterArtifactSignature -ArtifactPath $artifactDestination -SignaturePath $signatureDestination -PublicKeyPath $publicKeySnapshot)) {
        throw 'Copied signed Tauri artifact did not verify against the configured updater public key.'
    }
    Assert-NoUpdaterReparsePoint -Path $privateKey -Purpose 'Updater private key'
    if ((Get-Sha256Hex -LiteralPath $privateKey) -ne $privateKeyHash) {
        throw 'Updater private key changed while the signed build was running.'
    }
    $verifiedGitState = Assert-UpdaterGitStateUnchanged -InitialState $gitState -RequireClean
    $manifest = [ordered]@{
        schemaVersion=1
        version=$Version
        channel=$Channel
        identifier=[string]$tauriConfig.identifier
        endpoint=$endpointUrl
        installMode='passive'
        publicKeyFingerprint=$publicKeyFingerprint
        artifactFile=$installer.Name
        signatureFile=[System.IO.Path]::GetFileName($signaturePath)
        artifactSha256=Get-Sha256Hex -LiteralPath $artifactDestination
        signatureSha256=Get-Sha256Hex -LiteralPath $signatureDestination
        artifactSizeBytes=(Get-Item -LiteralPath $artifactDestination).Length
        cryptographicSignatureVerified=$true
        builtAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
        gitCommit=$verifiedGitState.Commit
        dirtyWorktree=$false
    }
    Write-Utf8NoBomJson -InputObject $manifest -LiteralPath ([System.IO.Path]::Combine($stagedOutput, 'signed-build-manifest.json'))
    if ([System.IO.Directory]::Exists($output) -or [System.IO.File]::Exists($output)) {
        throw 'Refusing to publish over an output path that appeared during the signed build.'
    }
    Assert-NoUpdaterReparsePoint -Path $privateKey -Purpose 'Updater private key'
    if ((Get-Sha256Hex -LiteralPath $privateKey) -ne $privateKeyHash) {
        throw 'Updater private key changed before signed-build publication.'
    }
    [void](Assert-UpdaterGitStateUnchanged -InitialState $gitState -RequireClean)
    [System.IO.Directory]::Move($stagedOutput, $output)
} catch {
    if ($null -ne $stagedOutput -and [System.IO.Directory]::Exists($stagedOutput)) {
        [System.IO.Directory]::Delete($stagedOutput, $true)
    }
    throw
} finally {
    [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY', $previousKey, 'Process')
    [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', $previousPassword, 'Process')
    [Environment]::SetEnvironmentVariable('QIJIANG_UPDATER_ENDPOINT', $previousRuntimeEndpoint, 'Process')
    [Environment]::SetEnvironmentVariable('QIJIANG_UPDATER_PUBLIC_KEY', $previousRuntimePublicKey, 'Process')
    [Environment]::SetEnvironmentVariable('QIJIANG_UPDATER_CHANNEL', $previousRuntimeChannel, 'Process')
    [Environment]::SetEnvironmentVariable('CARGO_TARGET_DIR', $previousCargoTargetDirectory, 'Process')
    $plainPassword = $null
    $password.Dispose()
    if ([System.IO.Directory]::Exists($temporaryDirectory)) { [System.IO.Directory]::Delete($temporaryDirectory, $true) }
}

[pscustomobject]@{
    Completed=$true
    Version=$Version
    Channel=$Channel
    Endpoint=$endpointUrl
    InstallMode='passive'
    CryptographicSignatureVerified=$true
    OutputDirectory=ConvertTo-UpdaterRedactedPath $output
    Upload=$false
    Install=$false
}
