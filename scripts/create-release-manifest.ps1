[CmdletBinding()]
param(
    [string]$InstallerPath,
    [string]$OutputDirectory,
    [string[]]$TestSummary = @()
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'windows\common.ps1')

function Get-Sha256Hash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    $stream = [System.IO.File]::Open(
        $LiteralPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
        $algorithm = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([System.BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '')
        } finally {
            $algorithm.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = [System.IO.Path]::Combine($repo, 'release') }
$OutputDirectory = Resolve-CallerPath -Path $OutputDirectory -BaseDirectory $InvocationDirectory
if (-not [string]::IsNullOrWhiteSpace($InstallerPath)) { $InstallerPath = Resolve-CallerPath -Path $InstallerPath -BaseDirectory $InvocationDirectory }
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
    $installer = Get-Item -LiteralPath $InstallerPath
}
$versionContext = Resolve-DeskPetVersionContext -RepositoryRoot $repo -ReleaseDirectory $null -InstallerPath $installer.FullName -ExplicitExpectedVersion ([string]$tauri.version)
Assert-DeskPetVersionContext -VersionContext $versionContext
$hash = Get-Sha256Hash -LiteralPath $installer.FullName
$commit = (& git -C $repo rev-parse HEAD 2>$null)
$dirty = [bool](& git -C $repo status --porcelain --untracked-files=normal)
$nodeVersion = (& node --version).Trim()
$rustVersion = (& rustc --version).Trim()
$tauriVersion = [string]$package.devDependencies.'@tauri-apps/cli'

[System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$output = $OutputDirectory
$manifestPath = Join-Path $output 'release-manifest.json'
$previousManifest = $null
if ([System.IO.File]::Exists($manifestPath)) {
    try { $previousManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $previousManifest = $null }
}
$versionedDestination = Join-Path $output $installer.Name
if (-not [string]::Equals([System.IO.Path]::GetFullPath($installer.FullName), [System.IO.Path]::GetFullPath($versionedDestination), [StringComparison]::OrdinalIgnoreCase)) {
    Copy-Item -LiteralPath $installer.FullName -Destination $versionedDestination -Force
}
$publicDestination = Join-Path $output $script:PublicInstallerName
if ([System.IO.File]::Exists($publicDestination)) {
    $existingPublicHash = Get-Sha256Hash -LiteralPath $publicDestination
    $previouslyManaged = $previousManifest -and
        [string]$previousManifest.publicInstallerFile -eq $script:PublicInstallerName -and
        [string]$previousManifest.publicInstallerSha256 -eq $existingPublicHash
    if ($existingPublicHash -ne $hash -and -not $previouslyManaged) {
        throw "Refusing to overwrite an unmanaged public installer: $script:PublicInstallerName"
    }
    if ($existingPublicHash -ne $hash) { Copy-Item -LiteralPath $versionedDestination -Destination $publicDestination -Force }
} else {
    Copy-Item -LiteralPath $versionedDestination -Destination $publicDestination
}
$publicItem = Get-Item -LiteralPath $publicDestination
$publicHash = Get-Sha256Hash -LiteralPath $publicItem.FullName
if ($publicHash -ne $hash) { throw 'Public and versioned installer hashes do not match.' }
$checksumLines = @(
    "$publicHash  $($publicItem.Name)",
    "$hash  $($installer.Name)"
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
    sha256 = $hash
    versionedInstallerSha256 = $hash
    publicInstallerSha256 = $publicHash
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
