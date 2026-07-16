[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$CurrentVersion,
    [Parameter(Mandatory)][string]$ArtifactPath,
    [Parameter(Mandatory)][string]$SignaturePath,
    [Parameter(Mandatory)][string]$PublicKeyPath,
    [Parameter(Mandatory)][string]$DownloadUrl,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$Platform = 'windows-x86_64',
    [AllowEmptyString()][string]$Notes = '',
    [string]$PublishedAtUtc = ([DateTimeOffset]::UtcNow.ToString('o'))
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. ([System.IO.Path]::Combine($PSScriptRoot, 'common.ps1'))

$artifact = Resolve-UpdaterPath -Path $ArtifactPath -BaseDirectory $InvocationDirectory
$signatureFile = Resolve-UpdaterPath -Path $SignaturePath -BaseDirectory $InvocationDirectory
$publicKey = Resolve-UpdaterPath -Path $PublicKeyPath -BaseDirectory $InvocationDirectory
$output = Resolve-UpdaterPath -Path $OutputPath -BaseDirectory $InvocationDirectory
if (-not [System.IO.File]::Exists($artifact)) { throw "Updater artifact not found: $([System.IO.Path]::GetFileName($artifact))" }
if (-not [System.IO.File]::Exists($publicKey)) { throw 'Updater public key not found.' }
if ([System.IO.File]::Exists($output)) { throw "Refusing to overwrite an existing latest.json: $([System.IO.Path]::GetFileName($output))" }
$DownloadUrl = Assert-UpdaterArtifactBinding -ArtifactPath $artifact -Version $Version -DownloadUrl $DownloadUrl
$signature = Get-UpdaterSignatureText -SignaturePath $signatureFile
$artifactSize = (Get-Item -LiteralPath $artifact).Length
if (-not (Test-UpdaterArtifactSignature -ArtifactPath $artifact -SignaturePath $signatureFile -PublicKeyPath $publicKey)) {
    throw 'Updater artifact signature verification failed.'
}
$document = New-UpdaterLatestDocument -Version $Version -CurrentVersion $CurrentVersion -DownloadUrl $DownloadUrl `
    -Signature $signature -Platform $Platform -PublishedAtUtc $PublishedAtUtc -ArtifactSizeBytes $artifactSize -Notes $Notes
$outputDirectory = [System.IO.Path]::GetDirectoryName($output)
if (-not [System.IO.Directory]::Exists($outputDirectory)) { [void][System.IO.Directory]::CreateDirectory($outputDirectory) }
Write-Utf8NoBomJson -InputObject $document -LiteralPath $output
[void](Test-UpdaterLatestDocument -LatestJsonPath $output -CurrentVersion $CurrentVersion -ExpectedVersion $Version -ExpectedPlatform $Platform -ExpectedArtifactSizeBytes $artifactSize)
[pscustomobject]@{ Created=$true; File=[System.IO.Path]::GetFileName($output); Version=$Version; Platform=$Platform; CryptographicSignatureVerified=$true }
