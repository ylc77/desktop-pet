[CmdletBinding()]
param(
    [string]$KeyPath,
    [string]$PublicKeyPath,
    [Alias('TestSigning')][switch]$VerifySigning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. ([System.IO.Path]::Combine($PSScriptRoot, 'common.ps1'))

if ([string]::IsNullOrWhiteSpace($KeyPath)) { $KeyPath = Get-DefaultUpdaterPrivateKeyPath }
$privateKeyPath = Assert-UpdaterPrivateKeyPath -KeyPath $KeyPath
if ([string]::IsNullOrWhiteSpace($PublicKeyPath)) { $PublicKeyPath = $privateKeyPath + '.pub' }
$publicKeyPath = Resolve-UpdaterPath -Path $PublicKeyPath -BaseDirectory ((Get-Location).ProviderPath)
$result = Test-UpdaterKeyFiles -PrivateKeyPath $privateKeyPath -PublicKeyPath $publicKeyPath

$probePassed = $false
if ($VerifySigning) {
    $tauriCli = [System.IO.Path]::Combine($script:UpdaterRepositoryRoot, 'node_modules', '.bin', 'tauri.cmd')
    if (-not [System.IO.File]::Exists($tauriCli)) { throw 'The repository Tauri CLI is not installed.' }
    $password = Read-Host 'Updater key password (input is hidden)' -AsSecureString
    if ($password.Length -lt 16) { throw 'Updater key password must contain at least 16 characters.' }
    $plainPassword = Convert-SecureStringToUpdaterPlainText -SecureString $password
    $previousKeyPath = [Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PATH', 'Process')
    $previousPassword = [Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', 'Process')
    $temporaryDirectory = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'qijiang-updater-key-check-' + [Guid]::NewGuid().ToString('N'))
    try {
        [void][System.IO.Directory]::CreateDirectory($temporaryDirectory)
        $probePath = [System.IO.Path]::Combine($temporaryDirectory, 'probe.bin')
        [System.IO.File]::WriteAllBytes($probePath, [byte[]](1, 7, 3, 9))
        [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PATH', $privateKeyPath, 'Process')
        [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', $plainPassword, 'Process')
        $signExit = Invoke-UpdaterToolProcess -FilePath $tauriCli -ArgumentList @(
            'signer','sign','--private-key-path',$privateKeyPath,$probePath
        ) -TimeoutSeconds 60
        if ($signExit -ne 0 -or -not [System.IO.File]::Exists($probePath + '.sig')) {
            throw 'Updater signing probe failed. Check the private-key password and key file.'
        }
        if (-not (Test-UpdaterArtifactSignature -ArtifactPath $probePath -SignaturePath ($probePath + '.sig') -PublicKeyPath $publicKeyPath)) {
            throw 'Updater signing probe used a private key that does not match the selected public key.'
        }
        $probePassed = $true
    } finally {
        [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PATH', $previousKeyPath, 'Process')
        [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', $previousPassword, 'Process')
        $plainPassword = $null
        $password.Dispose()
        if ([System.IO.Directory]::Exists($temporaryDirectory)) { [System.IO.Directory]::Delete($temporaryDirectory, $true) }
    }
}

[pscustomobject]@{
    Valid = $result.Valid
    PrivateKeyPath = $result.PrivateKeyPath
    PublicKeyPath = $result.PublicKeyPath
    PublicKeySha256 = $result.PublicKeySha256
    SigningProbePerformed = [bool]$VerifySigning
    SigningProbePassed = $probePassed
    CryptographicSignatureVerified = $probePassed
    NonEmptyPasswordVerified = $probePassed
    PrivatePublicKeyMatchVerified = $probePassed
}
