[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [string]$KeyPath,
    [string]$PublicKeyPath,
    [Parameter(Mandatory)][string]$BackupDirectoryOne,
    [Parameter(Mandatory)][string]$BackupDirectoryTwo
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. ([System.IO.Path]::Combine($PSScriptRoot, 'common.ps1'))

if ([string]::IsNullOrWhiteSpace($KeyPath)) { $KeyPath = Get-DefaultUpdaterPrivateKeyPath }
try {
    $privateKeyInput = Resolve-UpdaterPath -Path $KeyPath -BaseDirectory $InvocationDirectory
    $privateKey = Assert-UpdaterPrivateKeyPath -KeyPath $privateKeyInput
    if ([string]::IsNullOrWhiteSpace($PublicKeyPath)) { $PublicKeyPath = $privateKey + '.pub' }
    $publicKey = Normalize-UpdaterFilePath -Path (Resolve-UpdaterPath -Path $PublicKeyPath -BaseDirectory $InvocationDirectory)
    $backupOne = Normalize-UpdaterDirectoryPath -Path (Resolve-UpdaterPath -Path $BackupDirectoryOne -BaseDirectory $InvocationDirectory)
    $backupTwo = Normalize-UpdaterDirectoryPath -Path (Resolve-UpdaterPath -Path $BackupDirectoryTwo -BaseDirectory $InvocationDirectory)
} catch {
    $message = [string]$_.Exception.Message
    if ($message -in @(
        'The updater private key must be stored outside the repository.',
        'The updater private key path must use the .key extension.',
        'Updater key file path is invalid.',
        'Updater key backup directory path is invalid.',
        'Updater key backup directory path has no filesystem root.'
    )) { throw $message }
    throw 'Updater key backup input paths could not be resolved.'
}

Write-Warning 'A completed copy is not yet an offline backup. After verification, safely eject or physically disconnect both backup media and store them separately.'
$result = Invoke-UpdaterKeyBackup -PrivateKeyPath $privateKey -PublicKeyPath $publicKey `
    -BackupDirectoryOne $backupOne -BackupDirectoryTwo $backupTwo `
    -WhatIf:$WhatIfPreference
if ($result.Mode -eq 'Completed') {
    Write-Host 'Two encrypted updater key backups were copied and SHA-256 verified.'
    Write-Warning 'Both backup media are still online. Safely eject or physically disconnect each one before treating these copies as offline backups.'
} else {
    Write-Host 'Preview only. No backup directory or file was created.'
}
$result
