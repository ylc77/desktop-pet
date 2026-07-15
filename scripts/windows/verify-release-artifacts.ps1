[CmdletBinding()]
param(
    [string]$ReleaseDirectory = (Join-Path $PSScriptRoot '..\..\release')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$release = (Resolve-Path -LiteralPath $ReleaseDirectory).Path
$manifestPath = Join-Path $release 'release-manifest.json'
$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
$installer = Get-Item -LiteralPath (Join-Path $release $manifest.installerFile)
$hash = Get-FileHash -LiteralPath $installer.FullName -Algorithm SHA256
$signature = Get-AuthenticodeSignature -FilePath $installer.FullName
$checksumLine = Get-Content -Encoding ASCII -LiteralPath (Join-Path $release 'SHA256SUMS.txt')
$sensitiveHits = @(Get-ChildItem -LiteralPath $release -File | Where-Object Extension -in @('.json','.txt') | Select-String -Pattern 'C:\\Users\\|F:\\STAGE|\\\\[^\\]+\\[^\\]+' -ErrorAction SilentlyContinue)
$checks = @(
    [pscustomobject]@{ Check = 'Installer hash matches manifest'; Passed = $hash.Hash -eq $manifest.sha256; Details = $hash.Hash }
    [pscustomobject]@{ Check = 'Checksum file matches installer'; Passed = $checksumLine -eq "$($hash.Hash)  $($installer.Name)"; Details = $checksumLine }
    [pscustomobject]@{ Check = 'Manifest commit matches HEAD'; Passed = $manifest.gitCommit -eq (& git rev-parse HEAD).Trim(); Details = [string]$manifest.gitCommit }
    [pscustomobject]@{ Check = 'Manifest records clean build'; Passed = -not [bool]$manifest.dirtyWorktree; Details = "dirty=$($manifest.dirtyWorktree)" }
    [pscustomobject]@{ Check = 'Character schema remains version 1'; Passed = [int]$manifest.characterSchemaVersion -eq 1; Details = [string]$manifest.characterSchemaVersion }
    [pscustomobject]@{ Check = 'Release metadata has no local paths'; Passed = $sensitiveHits.Count -eq 0; Details = "hits=$($sensitiveHits.Count)" }
)
$checks | Format-Table -AutoSize
[pscustomobject]@{
    Installer = $installer.Name
    SizeBytes = $installer.Length
    SHA256 = $hash.Hash
    SignatureStatus = [string]$signature.Status
    ChecksPassed = @($checks | Where-Object Passed).Count
    ChecksFailed = @($checks | Where-Object { -not $_.Passed }).Count
} | ConvertTo-Json -Depth 4
if (@($checks | Where-Object { -not $_.Passed }).Count) { exit 2 }
