[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [string]$KeyPath,
    [switch]$Generate
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. ([System.IO.Path]::Combine($PSScriptRoot, 'common.ps1'))

if ([string]::IsNullOrWhiteSpace($KeyPath)) { $KeyPath = Get-DefaultUpdaterPrivateKeyPath }
$privateKeyPath = Assert-UpdaterPrivateKeyPath -KeyPath $KeyPath
$publicKeyPath = $privateKeyPath + '.pub'
$plan = [pscustomobject]@{
    Mode = $(if ($Generate -and -not $WhatIfPreference) { 'GenerateRequested' } else { 'PreviewOnly' })
    PrivateKeyPath = ConvertTo-UpdaterRedactedPath $privateKeyPath
    PublicKeyPath = ConvertTo-UpdaterRedactedPath $publicKeyPath
    RepositoryRoot = [System.IO.Path]::GetFileName($script:UpdaterRepositoryRoot)
    PasswordMode = 'Interactive secure prompt owned by the Tauri CLI'
    BackupRequired = $true
}

Write-Warning 'The updater private key controls every future trusted update. Keep encrypted offline backups in at least two separately controlled locations.'
Write-Warning 'Losing this key prevents existing installations from trusting future updates. Leaking it permits malicious updates.'

if (-not $Generate) {
    Write-Host 'Preview only. No key or directory was created. Re-run with -Generate after confirming the external path and backup plan.'
    return $plan
}

if ([System.IO.File]::Exists($privateKeyPath) -or [System.IO.File]::Exists($publicKeyPath)) {
    throw 'Refusing to overwrite an existing updater key pair.'
}
if (-not $PSCmdlet.ShouldProcess((ConvertTo-UpdaterRedactedPath $privateKeyPath), 'Generate encrypted Tauri updater key pair')) {
    return $plan
}

$tauriCli = [System.IO.Path]::Combine($script:UpdaterRepositoryRoot, 'node_modules', '.bin', 'tauri.cmd')
if (-not [System.IO.File]::Exists($tauriCli)) { throw 'The repository Tauri CLI is not installed.' }
$parentDirectory = [System.IO.Path]::GetDirectoryName($privateKeyPath)
[void][System.IO.Directory]::CreateDirectory($parentDirectory)

Write-Host 'The official Tauri CLI will now request a non-empty password interactively. The password is never accepted as a script argument or printed.'
& $tauriCli signer generate --write-keys $privateKeyPath
if ($LASTEXITCODE -ne 0) { throw "Tauri updater key generation failed with exit code $LASTEXITCODE." }
if (-not [System.IO.File]::Exists($privateKeyPath) -or -not [System.IO.File]::Exists($publicKeyPath)) {
    throw 'Tauri reported success, but the expected key-pair files were not both created.'
}
try {
    [void](Test-UpdaterKeyFiles -PrivateKeyPath $privateKeyPath -PublicKeyPath $publicKeyPath)
    $password = Read-Host 'Re-enter the non-empty updater key password for verification (input is hidden)' -AsSecureString
    if ($password.Length -eq 0) { throw 'Updater key password must not be empty.' }
    $plainPassword = Convert-SecureStringToUpdaterPlainText -SecureString $password
    $previousKeyPath = [Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PATH', 'Process')
    $previousPassword = [Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', 'Process')
    $probeDirectory = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'qijiang-key-initialize-' + [Guid]::NewGuid().ToString('N'))
    try {
        [void][System.IO.Directory]::CreateDirectory($probeDirectory)
        $probePath = [System.IO.Path]::Combine($probeDirectory, 'key-probe.bin')
        [System.IO.File]::WriteAllBytes($probePath, [byte[]](3,1,4,1,5,9))
        [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PATH', $privateKeyPath, 'Process')
        [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', $plainPassword, 'Process')
        $signExit = Invoke-UpdaterToolProcess -FilePath $tauriCli -ArgumentList @('signer','sign','--private-key-path',$privateKeyPath,$probePath) -TimeoutSeconds 60
        if ($signExit -ne 0 -or -not [System.IO.File]::Exists($probePath + '.sig')) {
            throw 'The generated key could not be unlocked with the non-empty verification password.'
        }
        if (-not (Test-UpdaterArtifactSignature -ArtifactPath $probePath -SignaturePath ($probePath + '.sig') -PublicKeyPath $publicKeyPath)) {
            throw 'The generated private and public updater keys do not match.'
        }
    } finally {
        [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PATH', $previousKeyPath, 'Process')
        [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', $previousPassword, 'Process')
        $plainPassword = $null
        $password.Dispose()
        if ([System.IO.Directory]::Exists($probeDirectory)) { [System.IO.Directory]::Delete($probeDirectory, $true) }
    }
} catch {
    # These exact files were created by this invocation and are unsafe to retain if unencrypted.
    if ([System.IO.File]::Exists($privateKeyPath)) { [System.IO.File]::Delete($privateKeyPath) }
    if ([System.IO.File]::Exists($publicKeyPath)) { [System.IO.File]::Delete($publicKeyPath) }
    throw
}
Write-Host 'Updater key pair generated. Verify it, create offline backups, and never add the private key to Git.'
Test-UpdaterKeyFiles -PrivateKeyPath $privateKeyPath -PublicKeyPath $publicKeyPath
