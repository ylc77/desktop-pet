[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('BeforeReboot','AfterReboot')][string]$Phase,
    [string]$StatePath
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = [System.IO.Path]::Combine($repo, 'qa-results', 'public-beta', 'restart', 'restart-state.json') }
. "$PSScriptRoot\common.ps1"
$path = Resolve-CallerPath -Path $StatePath -BaseDirectory $InvocationDirectory
[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path)) | Out-Null

if ($Phase -eq 'BeforeReboot') {
    $state = [ordered]@{
        schemaVersion=1; phase='awaiting-reboot'; recordedAtUtc=[DateTime]::UtcNow.ToString('o')
        gitCommit=(& git -C $repo rev-parse HEAD).Trim(); installRecords=@(Get-DeskPetInstallRecords).Count
        autostartEntries=@(Get-DeskPetRunEntries).Count; processCount=@(Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue).Count
        note='This script records state only. It does not restart Windows.'
    }
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Host "Pre-reboot state saved: $path"
    Write-Host 'Restart Windows manually only after reviewing the public beta checklist.'
    exit 0
}

if (-not [System.IO.File]::Exists($path)) { throw 'Pre-reboot state file was not found. Run -Phase BeforeReboot first.' }
$before = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
$after = [ordered]@{
    schemaVersion=1; phase='after-reboot'; before=$before; checkedAtUtc=[DateTime]::UtcNow.ToString('o')
    currentGitCommit=(& git -C $repo rev-parse HEAD).Trim(); installRecords=@(Get-DeskPetInstallRecords).Count
    autostartEntries=@(Get-DeskPetRunEntries).Count; processCount=@(Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue).Count
    requiresManualChecks=@('Confirm exactly one visible pet when autostart was enabled.','Confirm saved position is visible.','Confirm tray, animation, click, and drag behavior.','Disable autostart and perform a second manual restart.')
    status='requires_manual_review'
}
$after | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
Write-Host "Post-reboot state captured: $path"
