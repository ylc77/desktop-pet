[CmdletBinding()]
param(
    [string]$ReleaseDirectory = (Join-Path $PSScriptRoot '..\..\release')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$release = (Resolve-Path -LiteralPath $ReleaseDirectory).Path
$manifestPath = Join-Path $release 'release-manifest.json'
$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
$installer = Get-Item -LiteralPath (Join-Path $release $manifest.versionedInstallerFile)
$publicInstaller = Get-Item -LiteralPath (Join-Path $release $manifest.publicInstallerFile)
$hash = Get-FileHash -LiteralPath $installer.FullName -Algorithm SHA256
$publicHash = Get-FileHash -LiteralPath $publicInstaller.FullName -Algorithm SHA256
$signature = Get-AuthenticodeSignature -FilePath $publicInstaller.FullName
$checksumLines = @(Get-Content -Encoding UTF8 -LiteralPath (Join-Path $release 'SHA256SUMS.txt'))
$sensitiveHits = @(Get-ChildItem -LiteralPath $release -File | Where-Object Extension -in @('.json','.txt') | Select-String -Pattern 'C:\\Users\\|F:\\STAGE|\\\\[^\\]+\\[^\\]+' -ErrorAction SilentlyContinue)
$checks = @(
    [pscustomobject]@{ Check = 'Installer hash matches manifest'; Passed = $hash.Hash -eq $manifest.sha256; Details = $hash.Hash }
    [pscustomobject]@{ Check = 'Public installer hash matches versioned installer'; Passed = $publicHash.Hash -eq $hash.Hash -and $publicHash.Hash -eq $manifest.publicInstallerSha256; Details = $publicHash.Hash }
    [pscustomobject]@{ Check = 'Checksum file contains public installer'; Passed = $checksumLines -contains "$($publicHash.Hash)  $($publicInstaller.Name)"; Details = $checksumLines -join '; ' }
    [pscustomobject]@{ Check = 'Checksum file contains versioned installer'; Passed = $checksumLines -contains "$($hash.Hash)  $($installer.Name)"; Details = $checksumLines -join '; ' }
    [pscustomobject]@{ Check = 'Manifest records expected public filename'; Passed = [string]$manifest.publicInstallerFile -eq $script:PublicInstallerName; Details = [string]$manifest.publicInstallerFile }
    [pscustomobject]@{ Check = 'Manifest records expected executable filename'; Passed = [string]$manifest.mainExecutableFile -eq $script:ExecutableName; Details = [string]$manifest.mainExecutableFile }
    [pscustomobject]@{ Check = 'Manifest commit matches HEAD'; Passed = $manifest.gitCommit -eq (& git rev-parse HEAD).Trim(); Details = [string]$manifest.gitCommit }
    [pscustomobject]@{ Check = 'Manifest records clean build'; Passed = -not [bool]$manifest.dirtyWorktree; Details = "dirty=$($manifest.dirtyWorktree)" }
    [pscustomobject]@{ Check = 'Character schema remains version 1'; Passed = [int]$manifest.characterSchemaVersion -eq 1; Details = [string]$manifest.characterSchemaVersion }
    [pscustomobject]@{ Check = 'Release metadata has no local paths'; Passed = $sensitiveHits.Count -eq 0; Details = "hits=$($sensitiveHits.Count)" }
)
$checks | Format-Table -AutoSize
[pscustomobject]@{
    VersionedInstaller = $installer.Name
    PublicInstaller = $publicInstaller.Name
    SizeBytes = $publicInstaller.Length
    SHA256 = $publicHash.Hash
    SignatureStatus = [string]$signature.Status
    ChecksPassed = @($checks | Where-Object Passed).Count
    ChecksFailed = @($checks | Where-Object { -not $_.Passed }).Count
} | ConvertTo-Json -Depth 4
if (@($checks | Where-Object { -not $_.Passed }).Count) { exit 2 }
