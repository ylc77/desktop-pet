[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9_][a-z0-9_-]*$')]
    [string]$CharacterId,

    [string]$CharacterRoot,

    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$invocationDirectory = (Get-Location).ProviderPath
$repositoryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..'))

function Resolve-CharacterToolPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if ([string]::IsNullOrWhiteSpace($expanded)) { throw 'Path cannot be empty.' }
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($BaseDirectory, $expanded))
}

if ([string]::IsNullOrWhiteSpace($CharacterRoot)) {
    $CharacterRoot = [System.IO.Path]::Combine($repositoryRoot, 'public', 'characters')
} else {
    $CharacterRoot = Resolve-CharacterToolPath -Path $CharacterRoot -BaseDirectory $invocationDirectory
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = [System.IO.Path]::Combine($repositoryRoot, 'character-packages')
} else {
    $OutputDirectory = Resolve-CharacterToolPath -Path $OutputDirectory -BaseDirectory $invocationDirectory
}

if (-not [System.IO.Directory]::Exists($CharacterRoot)) {
    throw "Character root does not exist: $CharacterRoot"
}

$validatorPath = [System.IO.Path]::Combine($repositoryRoot, 'scripts', 'validate-character-pack.mjs')
$node = Get-Command node -CommandType Application -ErrorAction Stop
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $validationOutput = & $node.Source $validatorPath --root $CharacterRoot 2>&1
    $validationExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
foreach ($line in @($validationOutput)) { Write-Host ([string]$line) }
if ($validationExitCode -ne 0) {
    throw "Character validation failed with exit code $validationExitCode."
}

$sourceDirectory = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($CharacterRoot, $CharacterId))
if (-not [System.IO.Directory]::Exists($sourceDirectory)) {
    throw "Validated character does not exist: $CharacterId"
}
$sourceDirectoryInfo = New-Object System.IO.DirectoryInfo($sourceDirectory)
if (($sourceDirectoryInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Character source directory cannot be a symbolic link or junction: $sourceDirectory"
}
$manifestPath = [System.IO.Path]::Combine($sourceDirectory, 'manifest.json')
$framesPath = [System.IO.Path]::Combine($sourceDirectory, 'frames.json')
if (-not [System.IO.File]::Exists($manifestPath)) { throw "Character manifest is missing: $manifestPath" }
if (-not [System.IO.File]::Exists($framesPath)) { throw "Generated frames.json is missing: $framesPath" }

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$manifest.id -cne $CharacterId) {
    throw "Manifest id '$($manifest.id)' does not match requested character id '$CharacterId'."
}
$version = [string]$manifest.version
if ([string]::IsNullOrWhiteSpace($version)) { throw 'Character manifest version is required for packaging.' }
if ($version.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
    throw "Character version cannot be used in a package filename: $version"
}

[void][System.IO.Directory]::CreateDirectory($OutputDirectory)
$packageName = '{0}_{1}.qipet' -f $CharacterId, $version
$packagePath = [System.IO.Path]::Combine($OutputDirectory, $packageName)
if ([System.IO.File]::Exists($packagePath)) {
    throw "Package already exists and will not be overwritten: $packagePath"
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$temporaryPath = [System.IO.Path]::Combine($OutputDirectory, '.qipet-' + [Guid]::NewGuid().ToString('N') + '.tmp')
$archive = $null
$stream = $null
try {
    $stream = New-Object System.IO.FileStream(
        $temporaryPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    $archive = New-Object System.IO.Compression.ZipArchive(
        $stream,
        [System.IO.Compression.ZipArchiveMode]::Create,
        $false
    )
    $sourcePrefix = $sourceDirectory.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $files = New-Object 'System.Collections.Generic.List[string]'
    $pendingDirectories = New-Object System.Collections.Stack
    $pendingDirectories.Push($sourceDirectoryInfo)
    while ($pendingDirectories.Count -gt 0) {
        $directory = [System.IO.DirectoryInfo]$pendingDirectories.Pop()
        foreach ($item in $directory.GetFileSystemInfos()) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Character package cannot contain a symbolic link or junction: $($item.FullName)"
            }
            if ($item -is [System.IO.DirectoryInfo]) {
                $pendingDirectories.Push($item)
            } elseif ($item -is [System.IO.FileInfo]) {
                [void]$files.Add($item.FullName)
            }
        }
    }
    if ($files.Count -eq 0) { throw 'Character package does not contain any files.' }
    $files = $files.ToArray()
    [Array]::Sort($files, [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $files) {
        $fullPath = [System.IO.Path]::GetFullPath($file)
        if (-not $fullPath.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Character file escaped the source directory: $fullPath"
        }
        $entryName = $fullPath.Substring($sourcePrefix.Length).Replace([System.IO.Path]::DirectorySeparatorChar, '/')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive,
            $fullPath,
            $entryName,
            [System.IO.Compression.CompressionLevel]::Optimal
        )
    }
    $archive.Dispose()
    $archive = $null
    $stream.Dispose()
    $stream = $null
    [System.IO.File]::Move($temporaryPath, $packagePath)
} finally {
    if ($null -ne $archive) { $archive.Dispose() }
    if ($null -ne $stream) { $stream.Dispose() }
    if ([System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }
}

$packageInfo = New-Object System.IO.FileInfo($packagePath)
$sha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToUpperInvariant()
Write-Host "Character package: $packagePath"
Write-Host "SHA-256: $sha256"
[pscustomobject]@{
    CharacterId = $CharacterId
    Version = $version
    FileName = $packageInfo.Name
    Path = $packageInfo.FullName
    Length = $packageInfo.Length
    SHA256 = $sha256
}
