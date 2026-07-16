[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LatestJsonPath,
    [Parameter(Mandatory)][string]$CurrentVersion,
    [string]$ExpectedVersion,
    [string]$Platform = 'windows-x86_64',
    [string]$ArtifactPath,
    [string]$SignaturePath,
    [string]$PublicKeyPath
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. ([System.IO.Path]::Combine($PSScriptRoot, 'common.ps1'))

$latest = Resolve-UpdaterPath -Path $LatestJsonPath -BaseDirectory $InvocationDirectory
$verificationPaths = @(@($ArtifactPath, $SignaturePath, $PublicKeyPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($verificationPaths.Count -ne 0 -and $verificationPaths.Count -ne 3) {
    throw 'ArtifactPath, SignaturePath, and PublicKeyPath must be supplied together for cryptographic validation.'
}
if ($verificationPaths.Count -eq 3) {
    $artifact = Resolve-UpdaterPath -Path $ArtifactPath -BaseDirectory $InvocationDirectory
    $signature = Resolve-UpdaterPath -Path $SignaturePath -BaseDirectory $InvocationDirectory
    $publicKey = Resolve-UpdaterPath -Path $PublicKeyPath -BaseDirectory $InvocationDirectory
    Assert-UpdaterSignatureBinding -ArtifactPath $artifact -SignaturePath $signature
    $validation = Test-UpdaterLatestDocument -LatestJsonPath $latest -CurrentVersion $CurrentVersion -ExpectedVersion $ExpectedVersion `
        -ExpectedPlatform $Platform -ExpectedArtifactSizeBytes (Get-Item -LiteralPath $artifact).Length
    $document = Get-Content -LiteralPath $latest -Raw -Encoding UTF8 | ConvertFrom-Json
    $platformEntry = $document.platforms.PSObject.Properties[$Platform].Value
    [void](Assert-UpdaterArtifactBinding -ArtifactPath $artifact -Version $validation.Version -DownloadUrl ([string]$platformEntry.url))
    $metadataSignature = [string]$platformEntry.signature
    $fileSignature = Get-UpdaterSignatureText -SignaturePath $signature
    if ($metadataSignature -ne $fileSignature) { throw 'latest.json signature does not match the supplied .sig file.' }
    if (-not (Test-UpdaterArtifactSignature -ArtifactPath $artifact -SignaturePath $signature -PublicKeyPath $publicKey)) {
        throw 'Updater artifact signature verification failed.'
    }
    return [pscustomobject]@{ Valid=$true; Version=$validation.Version; Platforms=$validation.Platforms; CryptographicSignatureVerified=$true }
}
$metadataValidation = Test-UpdaterLatestDocument -LatestJsonPath $latest -CurrentVersion $CurrentVersion -ExpectedVersion $ExpectedVersion -ExpectedPlatform $Platform
[pscustomobject]@{ Valid=$true; Version=$metadataValidation.Version; Platforms=$metadataValidation.Platforms; CryptographicSignatureVerified=$false }
