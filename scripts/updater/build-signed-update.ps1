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
if (-not $PSCmdlet.ShouldProcess("version=$Version; channel=$Channel", 'Build signed updater artifacts')) { return $plan }

$tauriCli = [System.IO.Path]::Combine($script:UpdaterRepositoryRoot, 'node_modules', '.bin', 'tauri.cmd')
if (-not [System.IO.File]::Exists($tauriCli)) { throw 'The repository Tauri CLI is not installed.' }
$password = Read-Host 'Updater key password (input is hidden)' -AsSecureString
if ($password.Length -eq 0) { throw 'Updater key password must not be empty.' }
$plainPassword = Convert-SecureStringToUpdaterPlainText -SecureString $password
$previousKey = [Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY', 'Process')
$previousPassword = [Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', 'Process')
$previousRuntimeEndpoint = [Environment]::GetEnvironmentVariable('QIJIANG_UPDATER_ENDPOINT', 'Process')
$previousRuntimePublicKey = [Environment]::GetEnvironmentVariable('QIJIANG_UPDATER_PUBLIC_KEY', 'Process')
$previousRuntimeChannel = [Environment]::GetEnvironmentVariable('QIJIANG_UPDATER_CHANNEL', 'Process')
$temporaryDirectory = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'qijiang-signed-build-' + [Guid]::NewGuid().ToString('N'))
try {
    [void][System.IO.Directory]::CreateDirectory($temporaryDirectory)
    $overlayPath = [System.IO.Path]::Combine($temporaryDirectory, 'tauri.updater.overlay.json')
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

    Push-Location $script:UpdaterRepositoryRoot
    try {
        & npm run validate
        if ($LASTEXITCODE -ne 0) { throw "Project validation failed with exit code $LASTEXITCODE." }
        & $tauriCli build --bundles nsis --config $overlayPath
        if ($LASTEXITCODE -ne 0) { throw "Signed Tauri build failed with exit code $LASTEXITCODE." }
    } finally {
        Pop-Location
    }

    $bundleDirectory = [System.IO.Path]::Combine($script:UpdaterRepositoryRoot, 'src-tauri', 'target', 'release', 'bundle', 'nsis')
    $versionFilenamePattern = '(?<![0-9A-Za-z])' + [regex]::Escape($Version) + '(?![0-9A-Za-z])'
    $installer = Get-ChildItem -LiteralPath $bundleDirectory -Filter '*-setup.exe' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $versionFilenamePattern } |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $installer) { throw "No NSIS updater artifact for version $Version was found." }
    $signaturePath = $installer.FullName + '.sig'
    if (-not [System.IO.File]::Exists($signaturePath)) { throw 'Tauri build completed without the required updater signature artifact.' }
    [void](Get-UpdaterSignatureText -SignaturePath $signaturePath)
    if (-not (Test-UpdaterArtifactSignature -ArtifactPath $installer.FullName -SignaturePath $signaturePath -PublicKeyPath $publicKey)) {
        throw 'Signed Tauri artifact did not verify against the configured updater public key.'
    }

    [void][System.IO.Directory]::CreateDirectory($output)
    $artifactDestination = [System.IO.Path]::Combine($output, $installer.Name)
    $signatureDestination = [System.IO.Path]::Combine($output, [System.IO.Path]::GetFileName($signaturePath))
    [System.IO.File]::Copy($installer.FullName, $artifactDestination, $false)
    [System.IO.File]::Copy($signaturePath, $signatureDestination, $false)
    $manifest = [ordered]@{
        schemaVersion=1
        version=$Version
        channel=$Channel
        identifier=[string]$tauriConfig.identifier
        endpoint=$endpointUrl
        installMode='passive'
        publicKeyFingerprint=Get-UpdaterPublicKeyFingerprint -LiteralPath $publicKey
        artifactFile=$installer.Name
        signatureFile=[System.IO.Path]::GetFileName($signaturePath)
        artifactSha256=Get-Sha256Hex -LiteralPath $artifactDestination
        signatureSha256=Get-Sha256Hex -LiteralPath $signatureDestination
        artifactSizeBytes=(Get-Item -LiteralPath $artifactDestination).Length
        cryptographicSignatureVerified=$true
        builtAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
        gitCommit=$gitState.Commit
        dirtyWorktree=$false
    }
    Write-Utf8NoBomJson -InputObject $manifest -LiteralPath ([System.IO.Path]::Combine($output, 'signed-build-manifest.json'))
} catch {
    if ([System.IO.Directory]::Exists($output)) { [System.IO.Directory]::Delete($output, $true) }
    throw
} finally {
    [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY', $previousKey, 'Process')
    [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', $previousPassword, 'Process')
    [Environment]::SetEnvironmentVariable('QIJIANG_UPDATER_ENDPOINT', $previousRuntimeEndpoint, 'Process')
    [Environment]::SetEnvironmentVariable('QIJIANG_UPDATER_PUBLIC_KEY', $previousRuntimePublicKey, 'Process')
    [Environment]::SetEnvironmentVariable('QIJIANG_UPDATER_CHANNEL', $previousRuntimeChannel, 'Process')
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
