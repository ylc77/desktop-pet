[CmdletBinding()]
param([string]$ExpectedExecutable)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$entries = @(Get-DeskPetRunEntries)
$entries | Format-Table -AutoSize
if ($entries.Count -gt 1) { Write-Error "Duplicate autostart entries detected: $($entries.Count)"; exit 2 }
if ($ExpectedExecutable -and $entries.Count -eq 1) {
    $expected = [System.IO.Path]::GetFullPath($ExpectedExecutable)
    $matches = @($entries | Where-Object { $_.Value.Trim('"') -eq $expected })
    if ($matches.Count -ne 1) { Write-Error 'Autostart does not point to the expected executable.'; exit 3 }
}
Write-Host "Autostart entries: $($entries.Count)$(if($entries.Count -eq 0){' (disabled)'}else{''})"
