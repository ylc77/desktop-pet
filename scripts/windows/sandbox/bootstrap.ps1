[CmdletBinding()]
param([string]$InputRoot = 'C:\DeskPetQA\Input', [string]$ResultRoot = 'C:\DeskPetQA\Results')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $ResultRoot -Force | Out-Null
$env:DESK_PET_QA_CLEAN_ENVIRONMENT = '1'
Start-Transcript -Path (Join-Path $ResultRoot 'sandbox-bootstrap.log') -Force
try {
    $installer = Get-ChildItem (Join-Path $InputRoot 'release') -Filter '*setup.exe' -File | Select-Object -First 1
    if (-not $installer) { throw 'No NSIS installer was found in the read-only input mapping.' }
    $webView = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -ErrorAction SilentlyContinue
    [pscustomobject]@{ Installed=[bool]$webView; Version=$(if($webView){$webView.pv}else{$null}); CheckedAtUtc=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $ResultRoot 'webview2.json')
    & (Join-Path $InputRoot 'scripts\windows\install-smoke-test.ps1') -InstallerPath $installer.FullName -Confirm:$false
    . (Join-Path $InputRoot 'scripts\windows\common.ps1')
    $record = @(Get-DeskPetInstallRecords) | Select-Object -First 1
    if (-not $record) { throw 'Install registry entry was not found.' }
    $exe = Join-Path ([string]$record.InstallLocation) 'desk-pet-framework.exe'
    Start-Process -FilePath $exe -WindowStyle Hidden
    Start-Sleep -Seconds 3
    Start-Process -FilePath $exe -WindowStyle Hidden
    Start-Sleep -Seconds 3
    $processes = @(Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue)
    [pscustomobject]@{ ProcessCount=$processes.Count; SingleInstance=$processes.Count -eq 1; ExecutableExists=Test-Path $exe } | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $ResultRoot 'runtime.json')
    Write-Host 'Exit the pet normally from its tray/context menu, then press Enter here.'
    Read-Host | Out-Null
    if (Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue) { throw 'Application still runs; normal exit was not confirmed.' }
    & (Join-Path $InputRoot 'scripts\windows\uninstall-smoke-test.ps1') -Confirm:$false
    & (Join-Path $InputRoot 'scripts\windows\check-leftovers.ps1') | Out-File -Encoding UTF8 (Join-Path $ResultRoot 'leftovers.txt')
    & (Join-Path $PSScriptRoot 'collect-results.ps1') -ResultRoot $ResultRoot
} catch {
    $_ | Out-String | Set-Content -Encoding UTF8 (Join-Path $ResultRoot 'failure.txt')
    throw
} finally { Stop-Transcript }
