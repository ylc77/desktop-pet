[CmdletBinding()]
param(
    [string]$InstallerPath = (Join-Path $PSScriptRoot '..\src-tauri\target\release\bundle\nsis\Desk Pet Framework_0.1.0_x64-setup.exe'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\release'),
    [string[]]$TestSummary = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$installer = Get-Item -LiteralPath $InstallerPath
$package = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repo 'package.json') | ConvertFrom-Json
$tauri = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repo 'src-tauri\tauri.conf.json') | ConvertFrom-Json
$character = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repo 'public\characters\_placeholder\manifest.json') | ConvertFrom-Json
$hash = Get-FileHash -LiteralPath $installer.FullName -Algorithm SHA256
$commit = (& git -C $repo rev-parse HEAD 2>$null)
$dirty = [bool](& git -C $repo status --porcelain --untracked-files=no)
$nodeVersion = (& node --version).Trim()
$rustVersion = (& rustc --version).Trim()
$tauriVersion = [string]$package.devDependencies.'@tauri-apps/cli'

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$destination = Join-Path $OutputDirectory $installer.Name
Copy-Item -LiteralPath $installer.FullName -Destination $destination -Force
"$($hash.Hash)  $($installer.Name)" | Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Encoding ascii

$manifest = [ordered]@{
    applicationName = [string]$tauri.productName
    version = [string]$tauri.version
    architecture = 'x64'
    installerFile = $installer.Name
    installerSizeBytes = $installer.Length
    sha256 = $hash.Hash
    buildTimeUtc = [DateTime]::UtcNow.ToString('o')
    gitCommit = $(if ($commit) { $commit.Trim() } else { $null })
    dirtyWorktree = $dirty
    nodeVersion = $nodeVersion
    rustVersion = $rustVersion
    tauriCliVersionRange = $tauriVersion
    characterSchemaVersion = [int]$character.schemaVersion
    testSummary = @($TestSummary)
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'release-manifest.json') -Encoding utf8
Write-Host "Release artifacts created in: $OutputDirectory"
