[CmdletBinding()]
param(
    [string]$InstallerPath,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\release'),
    [string[]]$TestSummary = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'windows\common.ps1')
$package = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repo 'package.json') | ConvertFrom-Json
$tauri = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repo 'src-tauri\tauri.conf.json') | ConvertFrom-Json
$character = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repo 'public\characters\_placeholder\manifest.json') | ConvertFrom-Json
$bundleDirectory = Join-Path $repo 'src-tauri\target\release\bundle\nsis'
if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
    $installer = Get-ChildItem -LiteralPath $bundleDirectory -Filter '*-setup.exe' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith("$script:ProductName`_", [StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $installer) { throw "No versioned NSIS installer for $script:ProductName was found in $bundleDirectory." }
} else {
    $installer = Get-Item -LiteralPath (Resolve-Path -LiteralPath $InstallerPath).Path
}
$hash = Get-FileHash -LiteralPath $installer.FullName -Algorithm SHA256
$commit = (& git -C $repo rev-parse HEAD 2>$null)
$dirty = [bool](& git -C $repo status --porcelain --untracked-files=normal)
$nodeVersion = (& node --version).Trim()
$rustVersion = (& rustc --version).Trim()
$tauriVersion = [string]$package.devDependencies.'@tauri-apps/cli'

[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetFullPath($OutputDirectory)) | Out-Null
$output = [System.IO.Path]::GetFullPath($OutputDirectory)
$manifestPath = Join-Path $output 'release-manifest.json'
$previousManifest = $null
if ([System.IO.File]::Exists($manifestPath)) {
    try { $previousManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $previousManifest = $null }
}
$versionedDestination = Join-Path $output $installer.Name
Copy-Item -LiteralPath $installer.FullName -Destination $versionedDestination -Force
$publicDestination = Join-Path $output $script:PublicInstallerName
if ([System.IO.File]::Exists($publicDestination)) {
    $existingPublicHash = (Get-FileHash -LiteralPath $publicDestination -Algorithm SHA256).Hash
    $previouslyManaged = $previousManifest -and
        [string]$previousManifest.publicInstallerFile -eq $script:PublicInstallerName -and
        [string]$previousManifest.publicInstallerSha256 -eq $existingPublicHash
    if ($existingPublicHash -ne $hash.Hash -and -not $previouslyManaged) {
        throw "Refusing to overwrite an unmanaged public installer: $script:PublicInstallerName"
    }
    if ($existingPublicHash -ne $hash.Hash) { Copy-Item -LiteralPath $versionedDestination -Destination $publicDestination -Force }
} else {
    Copy-Item -LiteralPath $versionedDestination -Destination $publicDestination
}
$publicItem = Get-Item -LiteralPath $publicDestination
$publicHash = Get-FileHash -LiteralPath $publicItem.FullName -Algorithm SHA256
if ($publicHash.Hash -ne $hash.Hash) { throw 'Public and versioned installer hashes do not match.' }
$checksumLines = @(
    "$($publicHash.Hash)  $($publicItem.Name)",
    "$($hash.Hash)  $($installer.Name)"
)
[System.IO.File]::WriteAllLines((Join-Path $output 'SHA256SUMS.txt'), $checksumLines, (New-Object System.Text.UTF8Encoding($false)))

$manifest = [ordered]@{
    applicationName = [string]$tauri.productName
    version = [string]$tauri.version
    architecture = 'x64'
    identifier = [string]$tauri.identifier
    mainExecutableFile = "$([string]$tauri.mainBinaryName).exe"
    installerFile = $installer.Name
    versionedInstallerFile = $installer.Name
    publicInstallerFile = $publicItem.Name
    installerSizeBytes = $installer.Length
    sha256 = $hash.Hash
    versionedInstallerSha256 = $hash.Hash
    publicInstallerSha256 = $publicHash.Hash
    buildTimeUtc = [DateTime]::UtcNow.ToString('o')
    gitCommit = $(if ($commit) { $commit.Trim() } else { $null })
    dirtyWorktree = $dirty
    nodeVersion = $nodeVersion
    rustVersion = $rustVersion
    tauriCliVersionRange = $tauriVersion
    characterSchemaVersion = [int]$character.schemaVersion
    testSummary = @($TestSummary)
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8
Write-Host "Release artifacts created in: $output"
