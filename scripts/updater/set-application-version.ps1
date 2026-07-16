[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Version,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RepositoryRoot = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine($PSScriptRoot, '..', '..')
    ),

    [Parameter(DontShow = $true)]
    [scriptblock]$TestRollbackCopyAction,

    [Parameter(DontShow = $true)]
    [scriptblock]$TestBeforeFileReadAction,

    [Parameter(DontShow = $true)]
    [scriptblock]$TestBeforeBomReadAction
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. ([System.IO.Path]::Combine($PSScriptRoot, 'common.ps1'))

function Assert-ApplicationSemanticVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    # SemVer 2.0.0. Numeric identifiers cannot contain leading zeroes.
    $numericIdentifier = '(?:0|[1-9][0-9]*)'
    $nonNumericIdentifier = '(?:[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
    $prereleaseIdentifier = "(?:$numericIdentifier|$nonNumericIdentifier)"
    $pattern = "^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-$prereleaseIdentifier(?:\.$prereleaseIdentifier)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"

    if (-not [System.Text.RegularExpressions.Regex]::IsMatch($Value, $pattern)) {
        throw 'Invalid semantic version.'
    }
}

function Get-RequiredFileText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath
    )

    if (-not [System.IO.File]::Exists($LiteralPath)) {
        throw "A required application version file is missing: $([System.IO.Path]::GetFileName($LiteralPath))"
    }

    try {
        return [System.IO.File]::ReadAllText($LiteralPath)
    }
    catch {
        throw "Unable to read required application version file: $([System.IO.Path]::GetFileName($LiteralPath))"
    }
}

function Get-RequiredRegexMatch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $matches = [System.Text.RegularExpressions.Regex]::Matches(
        $Text,
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::Multiline
    )
    if ($matches.Count -ne 1) {
        throw "Expected exactly one $Description version field, but found $($matches.Count)."
    }

    return $matches[0]
}

function Set-RequiredRegexVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [Parameter(Mandatory = $true)]
        [string]$NewVersion,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    [void](Get-RequiredRegexMatch -Text $Text -Pattern $Pattern -Description $Description)
    $regex = New-Object System.Text.RegularExpressions.Regex(
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::Multiline
    )
    $replaceVersion = [System.Text.RegularExpressions.MatchEvaluator]{
        param([System.Text.RegularExpressions.Match]$match)
        return $match.Groups['prefix'].Value + $NewVersion + $match.Groups['suffix'].Value
    }
    return $regex.Replace($Text, $replaceVersion, 1)
}

function ConvertFrom-RequiredJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    try {
        return $Text | ConvertFrom-Json
    }
    catch {
        throw "$Description is not valid JSON."
    }
}

function ConvertFrom-RequiredJsonDictionary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            return $Text | ConvertFrom-Json -AsHashtable
        }
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
        $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $serializer.MaxJsonLength = [int]::MaxValue
        $serializer.RecursionLimit = 1000
        return $serializer.DeserializeObject($Text)
    }
    catch {
        throw "$Description is not valid JSON."
    }
}

function Get-RequiredJsonPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "$Description does not contain the required '$Name' property."
    }
    return $property.Value
}

function Assert-CleanVersionWorktree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        throw 'Git is required to verify that the version worktree is clean.'
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $status = @(& $git.Source -C $Root status --porcelain=v1 --untracked-files=all 2>$null)
        $gitExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($gitExitCode -ne 0) {
        throw 'The repository root is not a readable Git worktree.'
    }
    if ($status.Count -ne 0) {
        throw 'The application version cannot be changed because the Git working tree is not clean.'
    }
}

function Get-Utf8FileBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [bool]$IncludeBom
    )

    $encoding = New-Object System.Text.UTF8Encoding($IncludeBom)
    return $encoding.GetBytes($Text)
}

function Test-FileHasUtf8Bom {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath
    )

    try {
        $bytes = [System.IO.File]::ReadAllBytes($LiteralPath)
    }
    catch {
        throw "Unable to inspect required application version file encoding: $([System.IO.Path]::GetFileName($LiteralPath))"
    }
    return $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
}

function Invoke-AtomicVersionWrite {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Changes,

        [scriptblock]$RollbackCopyAction
    )

    $prepared = @()
    $transactionCompleted = $false
    $failureMessage = $null
    $cleanupFailed = $false
    $preservedBackupPaths = @{}
    try {
        foreach ($change in $Changes) {
            $suffix = [Guid]::NewGuid().ToString('N')
            $temporaryPath = $change.Path + ".version-sync.$suffix.tmp"
            $backupPath = $change.Path + ".version-sync.$suffix.bak"
            $bytes = Get-Utf8FileBytes -Text $change.NewText -IncludeBom ([bool]$change.IncludeBom)
            [System.IO.File]::WriteAllBytes($temporaryPath, $bytes)
            $prepared += [pscustomobject]@{
                Path = $change.Path
                TemporaryPath = $temporaryPath
                BackupPath = $backupPath
            }
        }

        foreach ($item in $prepared) {
            [System.IO.File]::Replace($item.TemporaryPath, $item.Path, $item.BackupPath, $true)
        }
        $transactionCompleted = $true
    }
    catch {
        $rollbackFailedFiles = @()
        for ($index = $prepared.Count - 1; $index -ge 0; $index--) {
            $item = $prepared[$index]
            if ([System.IO.File]::Exists($item.BackupPath)) {
                try {
                    if ($null -eq $RollbackCopyAction) {
                        [System.IO.File]::Copy($item.BackupPath, $item.Path, $true)
                    }
                    else {
                        & $RollbackCopyAction $item.BackupPath $item.Path
                    }
                }
                catch {
                    $rollbackFailedFiles += [System.IO.Path]::GetFileName($item.Path)
                    $preservedBackupPaths[$item.BackupPath] = $true
                }
            }
        }

        if ($rollbackFailedFiles.Count -gt 0) {
            $failureMessage = 'Application version synchronization failed and rollback failed for: ' + (($rollbackFailedFiles | Sort-Object -Unique) -join ', ') + '. Recovery .bak files were preserved beside the affected files; stop and inspect the worktree.'
        }
        else {
            $failureMessage = 'Application version synchronization failed; all modified files were restored.'
        }
    }
    finally {
        foreach ($item in $prepared) {
            $cleanupPaths = @($item.TemporaryPath)
            if (-not $preservedBackupPaths.ContainsKey($item.BackupPath)) {
                $cleanupPaths += $item.BackupPath
            }
            foreach ($cleanupPath in $cleanupPaths) {
                if ([System.IO.File]::Exists($cleanupPath)) {
                    try {
                        [System.IO.File]::Delete($cleanupPath)
                    }
                    catch {
                        $cleanupFailed = $true
                    }
                }
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($failureMessage)) {
        if ($cleanupFailed) {
            $failureMessage += ' One or more transaction files also could not be cleaned up.'
        }
        throw $failureMessage
    }
    if (-not $transactionCompleted) {
        throw 'Application version synchronization did not complete.'
    }
    if ($cleanupFailed) {
        throw 'Application version files were updated, but transaction cleanup failed. Stop and inspect version-sync temporary files before continuing.'
    }
}

Assert-ApplicationSemanticVersion -Value $Version
if (($null -ne $TestRollbackCopyAction -or
        $null -ne $TestBeforeFileReadAction -or
        $null -ne $TestBeforeBomReadAction) -and
    $env:DESK_PET_VERSION_TEST_MODE -ne '1') {
    throw 'Version fault-injection hooks are available only to the isolated version regression test.'
}
try {
    $resolvedRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
}
catch {
    throw 'Application version repository path is invalid.'
}
Assert-CleanVersionWorktree -Root $resolvedRoot

try {
    $paths = [ordered]@{
        PackageJson = [System.IO.Path]::Combine($resolvedRoot, 'package.json')
        PackageLock = [System.IO.Path]::Combine($resolvedRoot, 'package-lock.json')
        TauriConfig = [System.IO.Path]::Combine($resolvedRoot, 'src-tauri', 'tauri.conf.json')
        CargoManifest = [System.IO.Path]::Combine($resolvedRoot, 'src-tauri', 'Cargo.toml')
        CargoLock = [System.IO.Path]::Combine($resolvedRoot, 'src-tauri', 'Cargo.lock')
    }
}
catch {
    throw 'Unable to resolve required application version file paths.'
}

$texts = @{}
if ($null -ne $TestBeforeFileReadAction) {
    & $TestBeforeFileReadAction
}
foreach ($entry in $paths.GetEnumerator()) {
    $texts[$entry.Key] = Get-RequiredFileText -LiteralPath $entry.Value
}

$packageJson = ConvertFrom-RequiredJson -Text $texts.PackageJson -Description 'package.json'
$packageLock = ConvertFrom-RequiredJsonDictionary -Text $texts.PackageLock -Description 'package-lock.json'
$tauriConfig = ConvertFrom-RequiredJson -Text $texts.TauriConfig -Description 'src-tauri/tauri.conf.json'
$packageLockRoot = $null
if ($packageLock.ContainsKey('packages') -and $packageLock['packages'].ContainsKey('')) {
    $packageLockRoot = $packageLock['packages']['']
}
if ($null -eq $packageLockRoot) {
    throw 'package-lock.json does not contain the root package record.'
}

$cargoManifestVersionPattern = '(?ms)(?<prefix>^\[package\][\r\n]+(?:(?!^\[).)*?^version\s*=\s*")(?<value>[^"]+)(?<suffix>"[^\r\n]*$)'
$cargoManifestNamePattern = '(?ms)^\[package\][\r\n]+(?:(?!^\[).)*?^name\s*=\s*"(?<value>[^"]+)"[^\r\n]*$'
$cargoManifestVersion = Get-RequiredRegexMatch -Text $texts.CargoManifest -Pattern $cargoManifestVersionPattern -Description 'Cargo.toml package'
$cargoPackageNameMatch = Get-RequiredRegexMatch -Text $texts.CargoManifest -Pattern $cargoManifestNamePattern -Description 'Cargo.toml package name'
$cargoPackageName = $cargoPackageNameMatch.Groups['value'].Value
$escapedCargoPackageName = [System.Text.RegularExpressions.Regex]::Escape($cargoPackageName)
$cargoLockVersionPattern = '(?ms)(?<prefix>^\[\[package\]\]\r?\nname\s*=\s*"{0}"\r?\nversion\s*=\s*")(?<value>[^"]+)(?<suffix>"[^\r\n]*$)' -f $escapedCargoPackageName
$cargoLockVersion = Get-RequiredRegexMatch -Text $texts.CargoLock -Pattern $cargoLockVersionPattern -Description 'Cargo.lock application package'

$currentVersions = [ordered]@{
    PackageJson = [string]$packageJson.version
    PackageLock = [string]$packageLock['version']
    PackageLockRoot = [string]$packageLockRoot['version']
    TauriConfig = [string]$tauriConfig.version
    CargoManifest = [string]$cargoManifestVersion.Groups['value'].Value
    CargoLock = [string]$cargoLockVersion.Groups['value'].Value
}
$distinctVersions = @($currentVersions.Values | Select-Object -Unique)
if ($distinctVersions.Count -ne 1) {
    throw 'Existing application versions are inconsistent across the required version files.'
}
$currentVersion = [string]$distinctVersions[0]
Assert-ApplicationSemanticVersion -Value $currentVersion

if ($currentVersion -eq $Version) {
    return [pscustomobject]@{
        Mode = 'AlreadyCurrent'
        CurrentVersion = $currentVersion
        TargetVersion = $Version
        Files = @($paths.Values | ForEach-Object { [System.IO.Path]::GetFileName($_) })
    }
}
if ((Compare-SemVer -Left $Version -Right $currentVersion) -le 0) {
    throw "Application version must have higher SemVer precedence: current=$currentVersion; target=$Version"
}

$jsonTopLevelVersionPattern = '^(?<prefix> {2}"version"\s*:\s*")[^"]+(?<suffix>"\s*,?\s*)$'
$packageLockRootVersionPattern = '^(?<prefix> {6}"version"\s*:\s*")[^"]+(?<suffix>"\s*,?\s*)$'
$newTexts = [ordered]@{
    PackageJson = Set-RequiredRegexVersion -Text $texts.PackageJson -Pattern $jsonTopLevelVersionPattern -NewVersion $Version -Description 'package.json top-level'
    PackageLock = Set-RequiredRegexVersion -Text (
        Set-RequiredRegexVersion -Text $texts.PackageLock -Pattern $jsonTopLevelVersionPattern -NewVersion $Version -Description 'package-lock.json top-level'
    ) -Pattern $packageLockRootVersionPattern -NewVersion $Version -Description 'package-lock.json root package'
    TauriConfig = Set-RequiredRegexVersion -Text $texts.TauriConfig -Pattern $jsonTopLevelVersionPattern -NewVersion $Version -Description 'tauri.conf.json top-level'
    CargoManifest = Set-RequiredRegexVersion -Text $texts.CargoManifest -Pattern $cargoManifestVersionPattern -NewVersion $Version -Description 'Cargo.toml package'
    CargoLock = Set-RequiredRegexVersion -Text $texts.CargoLock -Pattern $cargoLockVersionPattern -NewVersion $Version -Description 'Cargo.lock application package'
}

# Parse and validate every candidate before the first file is replaced.
$newPackageJson = ConvertFrom-RequiredJson -Text $newTexts.PackageJson -Description 'updated package.json'
$newPackageLock = ConvertFrom-RequiredJsonDictionary -Text $newTexts.PackageLock -Description 'updated package-lock.json'
$newTauriConfig = ConvertFrom-RequiredJson -Text $newTexts.TauriConfig -Description 'updated src-tauri/tauri.conf.json'
$newPackageLockRoot = $newPackageLock['packages']['']
$newCargoManifestVersion = Get-RequiredRegexMatch -Text $newTexts.CargoManifest -Pattern $cargoManifestVersionPattern -Description 'updated Cargo.toml package'
$newCargoLockVersion = Get-RequiredRegexMatch -Text $newTexts.CargoLock -Pattern $cargoLockVersionPattern -Description 'updated Cargo.lock application package'
$candidateVersions = @(
    [string]$newPackageJson.version,
    [string]$newPackageLock['version'],
    [string]$newPackageLockRoot['version'],
    [string]$newTauriConfig.version,
    [string]$newCargoManifestVersion.Groups['value'].Value,
    [string]$newCargoLockVersion.Groups['value'].Value
)
if (@($candidateVersions | Where-Object { $_ -ne $Version }).Count -ne 0) {
    throw 'Version candidate validation failed before any file was modified.'
}

$changes = @()
if ($null -ne $TestBeforeBomReadAction) {
    & $TestBeforeBomReadAction
}
foreach ($entry in $paths.GetEnumerator()) {
    $changes += [pscustomobject]@{
        Path = $entry.Value
        NewText = $newTexts[$entry.Key]
        IncludeBom = Test-FileHasUtf8Bom -LiteralPath $entry.Value
    }
}

if (-not $PSCmdlet.ShouldProcess('five application version files', "Synchronize version $currentVersion -> $Version")) {
    return [pscustomobject]@{
        Mode = 'PreviewOnly'
        CurrentVersion = $currentVersion
        TargetVersion = $Version
        Files = @('package.json', 'package-lock.json', 'tauri.conf.json', 'Cargo.toml', 'Cargo.lock')
    }
}

Invoke-AtomicVersionWrite -Changes $changes -RollbackCopyAction $TestRollbackCopyAction

return [pscustomobject]@{
    Mode = 'Completed'
    CurrentVersion = $currentVersion
    TargetVersion = $Version
    Files = @('package.json', 'package-lock.json', 'tauri.conf.json', 'Cargo.toml', 'Cargo.lock')
}
