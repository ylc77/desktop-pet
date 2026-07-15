[CmdletBinding()]
param([string]$OutputPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sandbox = try {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -ErrorAction Stop
    @{ available = $true; state = [string]$feature.State; reason = $null }
} catch { @{ available = $false; state = 'Unknown'; reason = $_.Exception.Message } }
$hyperVCommand = Get-Command Get-VM -ErrorAction SilentlyContinue
$hyperV = @{ commandAvailable = [bool]$hyperVCommand; virtualMachines = @(); reason = $null }
if ($hyperVCommand) {
    try { $hyperV.virtualMachines = @(Get-VM | Select-Object Name, State, Version, Generation) }
    catch { $hyperV.reason = $_.Exception.Message }
}
$vmrun = Get-Command vmrun -ErrorAction SilentlyContinue
$virtualBox = Get-Command VBoxManage -ErrorAction SilentlyContinue
$result = [ordered]@{
    detectedAtUtc = [DateTime]::UtcNow.ToString('o')
    sandbox = $sandbox
    hyperV = $hyperV
    vmware = @{ commandAvailable = [bool]$vmrun; path = $(if ($vmrun) { $vmrun.Source } else { $null }) }
    virtualBox = @{ commandAvailable = [bool]$virtualBox; path = $(if ($virtualBox) { $virtualBox.Source } else { $null }) }
    note = 'Detection only. No optional feature, VM, snapshot, or shared directory was changed.'
}
$json = $result | ConvertTo-Json -Depth 8
if ($OutputPath) { $json | Set-Content -Encoding UTF8 -LiteralPath $OutputPath }
$json
