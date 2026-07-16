Set-StrictMode -Version Latest

$script:RepositoryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
$script:TauriConfigPath = [System.IO.Path]::Combine($script:RepositoryRoot, 'src-tauri', 'tauri.conf.json')
if (-not [System.IO.File]::Exists($script:TauriConfigPath)) { throw "Tauri configuration not found: $script:TauriConfigPath" }
$script:TauriConfig = Get-Content -LiteralPath $script:TauriConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$script:ProductName = [string]$script:TauriConfig.productName
$script:MainBinaryName = [string]$script:TauriConfig.mainBinaryName
$script:ExecutableName = "$script:MainBinaryName.exe"
$script:ProcessName = $script:MainBinaryName
$script:AppIdentifier = [string]$script:TauriConfig.identifier
$script:PublicInstallerName = "$script:ProductName.exe"
# Compatibility-only identifiers for detecting leftovers from pre-rebrand installations.
$script:LegacyProductNames = @('Desk Pet Framework')
$script:LegacyExecutableNames = @('desk-pet-framework.exe')
$script:LegacyProcessNames = @('desk-pet-framework')

function Resolve-CallerPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BaseDirectory
    )
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if ([string]::IsNullOrWhiteSpace($expanded)) { throw 'Path is empty.' }
    if ([string]::IsNullOrWhiteSpace($BaseDirectory) -or -not [System.IO.Path]::IsPathRooted($BaseDirectory)) {
        throw "BaseDirectory is not an absolute path: $BaseDirectory"
    }
    if ([System.IO.Path]::IsPathRooted($expanded)) { return [System.IO.Path]::GetFullPath($expanded) }
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($BaseDirectory, $expanded))
}

function Get-DeskPetInstallerVersion {
    param([Parameter(Mandatory)][string]$InstallerPath)
    if (-not [System.IO.File]::Exists($InstallerPath)) { throw "Installer not found: $InstallerPath" }
    $fileName = [System.IO.Path]::GetFileName($InstallerPath)
    $pattern = '^' + [regex]::Escape($script:ProductName) + '_(?<version>.+?)_[^_]+-setup\.exe$'
    if ($fileName -match $pattern) {
        [void](ConvertFrom-DeskPetSemVer ([string]$Matches['version']))
        return [string]$Matches['version']
    }
    $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($InstallerPath)
    foreach ($candidate in @([string]$versionInfo.ProductVersion, [string]$versionInfo.FileVersion)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and $candidate -match '(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)') {
            return [string]$Matches['version']
        }
    }
    throw "Installer version could not be determined: $fileName"
}

function Resolve-DeskPetVersionContext {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [AllowNull()][string]$ReleaseDirectory,
        [AllowNull()][string]$InstallerPath,
        [AllowNull()][string]$ExplicitExpectedVersion
    )
    $configPath = [System.IO.Path]::Combine($RepositoryRoot, 'src-tauri', 'tauri.conf.json')
    if (-not [System.IO.File]::Exists($configPath)) { throw "Tauri configuration not found: $configPath" }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $configVersion = [string](Get-ObjectPropertyValue $config 'version')
    $packageVersion = $null
    $cargoVersion = $null
    $cargoLockVersion = $null
    $packagePath = [System.IO.Path]::Combine($RepositoryRoot, 'package.json')
    if ([System.IO.File]::Exists($packagePath)) {
        $package = Get-Content -LiteralPath $packagePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $packageVersion = [string](Get-ObjectPropertyValue $package 'version')
    }
    $cargoManifestPath = [System.IO.Path]::Combine($RepositoryRoot, 'src-tauri', 'Cargo.toml')
    $cargoPackageName = $null
    if ([System.IO.File]::Exists($cargoManifestPath)) {
        $cargoManifestText = [System.IO.File]::ReadAllText($cargoManifestPath, [System.Text.Encoding]::UTF8)
        $cargoPackageMatch = [regex]::Match($cargoManifestText, '(?ms)^\[package\]\s*(?<package>.*?)(?=^\[|\z)')
        if ($cargoPackageMatch.Success) {
            $cargoVersionMatch = [regex]::Match($cargoPackageMatch.Groups['package'].Value, '(?m)^\s*version\s*=\s*"(?<value>[^"]+)"\s*$')
            $cargoNameMatch = [regex]::Match($cargoPackageMatch.Groups['package'].Value, '(?m)^\s*name\s*=\s*"(?<value>[^"]+)"\s*$')
            if ($cargoVersionMatch.Success) { $cargoVersion = $cargoVersionMatch.Groups['value'].Value }
            if ($cargoNameMatch.Success) { $cargoPackageName = $cargoNameMatch.Groups['value'].Value }
        }
    }
    $cargoLockPath = [System.IO.Path]::Combine($RepositoryRoot, 'src-tauri', 'Cargo.lock')
    if ([System.IO.File]::Exists($cargoLockPath) -and -not [string]::IsNullOrWhiteSpace($cargoPackageName)) {
        $cargoLockText = [System.IO.File]::ReadAllText($cargoLockPath, [System.Text.Encoding]::UTF8)
        foreach ($block in [regex]::Matches($cargoLockText, '(?ms)^\[\[package\]\]\s*(?<package>.*?)(?=^\[\[package\]\]|\z)')) {
            $nameMatch = [regex]::Match($block.Groups['package'].Value, '(?m)^\s*name\s*=\s*"(?<value>[^"]+)"\s*$')
            if (-not $nameMatch.Success -or $nameMatch.Groups['value'].Value -ne $cargoPackageName) { continue }
            $versionMatch = [regex]::Match($block.Groups['package'].Value, '(?m)^\s*version\s*=\s*"(?<value>[^"]+)"\s*$')
            if ($versionMatch.Success) { $cargoLockVersion = $versionMatch.Groups['value'].Value }
            break
        }
    }
    $manifestVersion = $null
    $manifestPath = $null
    if (-not [string]::IsNullOrWhiteSpace($ReleaseDirectory)) {
        $manifestPath = [System.IO.Path]::Combine($ReleaseDirectory, 'release-manifest.json')
        if ([System.IO.File]::Exists($manifestPath)) {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $manifestVersion = [string](Get-ObjectPropertyValue $manifest 'version')
        }
    }
    $installerVersion = if ([string]::IsNullOrWhiteSpace($InstallerPath)) { $null } else { Get-DeskPetInstallerVersion -InstallerPath $InstallerPath }
    # Tauri is the product's authoritative version source. Explicit QA input and
    # generated metadata are assertions against it, never competing defaults.
    $expectedVersion = $configVersion
    [pscustomobject]@{
        ExpectedVersion = [string]$expectedVersion
        ExplicitExpectedVersion = $ExplicitExpectedVersion
        InstallerVersion = $installerVersion
        ManifestVersion = $manifestVersion
        ConfigVersion = $configVersion
        PackageVersion = $packageVersion
        CargoVersion = $cargoVersion
        CargoLockVersion = $cargoLockVersion
        ManifestPath = $manifestPath
        InstallerPath = $InstallerPath
    }
}

function Assert-DeskPetVersionContext {
    param(
        [Parameter(Mandatory)][object]$VersionContext,
        [AllowEmptyCollection()][string[]]$RegistryVersions = @()
    )
    $expected = [string](Get-ObjectPropertyValue $VersionContext 'ExpectedVersion')
    $installer = [string](Get-ObjectPropertyValue $VersionContext 'InstallerVersion')
    $manifest = [string](Get-ObjectPropertyValue $VersionContext 'ManifestVersion')
    $config = [string](Get-ObjectPropertyValue $VersionContext 'ConfigVersion')
    $explicit = [string](Get-ObjectPropertyValue $VersionContext 'ExplicitExpectedVersion')
    $package = [string](Get-ObjectPropertyValue $VersionContext 'PackageVersion')
    $cargo = [string](Get-ObjectPropertyValue $VersionContext 'CargoVersion')
    $cargoLock = [string](Get-ObjectPropertyValue $VersionContext 'CargoLockVersion')
    $actualRegistryVersions = @($RegistryVersions | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $mismatch = [string]::IsNullOrWhiteSpace($expected) -or
        (-not [string]::IsNullOrWhiteSpace($installer) -and $installer -ne $expected) -or
        (-not [string]::IsNullOrWhiteSpace($manifest) -and $manifest -ne $expected) -or
        (-not [string]::IsNullOrWhiteSpace($config) -and $config -ne $expected) -or
        (-not [string]::IsNullOrWhiteSpace($explicit) -and $explicit -ne $expected) -or
        (-not [string]::IsNullOrWhiteSpace($package) -and $package -ne $expected) -or
        (-not [string]::IsNullOrWhiteSpace($cargo) -and $cargo -ne $expected) -or
        (-not [string]::IsNullOrWhiteSpace($cargoLock) -and $cargoLock -ne $expected) -or
        @($actualRegistryVersions | Where-Object { $_ -ne $expected }).Count -gt 0
    if ($mismatch) {
        $registryText = if ($actualRegistryVersions.Count) { $actualRegistryVersions -join ',' } else { '<not checked>' }
        throw ("Version mismatch: expected={0}; registry={1}; installer={2}; releaseManifest={3}; tauri={4}; explicit={5}; package={6}; cargo={7}; cargoLock={8}" -f
            $expected, $registryText,
            $(if ([string]::IsNullOrWhiteSpace($installer)) { '<not provided>' } else { $installer }),
            $(if ([string]::IsNullOrWhiteSpace($manifest)) { '<missing>' } else { $manifest }),
            $(if ([string]::IsNullOrWhiteSpace($config)) { '<missing>' } else { $config }),
            $(if ([string]::IsNullOrWhiteSpace($explicit)) { '<not provided>' } else { $explicit }),
            $(if ([string]::IsNullOrWhiteSpace($package)) { '<missing>' } else { $package }),
            $(if ([string]::IsNullOrWhiteSpace($cargo)) { '<missing>' } else { $cargo }),
            $(if ([string]::IsNullOrWhiteSpace($cargoLock)) { '<missing>' } else { $cargoLock }))
    }
}

function ConvertFrom-DeskPetSemVer {
    param([Parameter(Mandatory)][string]$Version)
    $match = [regex]::Match($Version, '^(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)(?:-(?<pre>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$')
    if (-not $match.Success) { throw "Invalid SemVer: $Version" }
    [pscustomobject]@{
        Original = $Version
        Major = [int64]$match.Groups['major'].Value
        Minor = [int64]$match.Groups['minor'].Value
        Patch = [int64]$match.Groups['patch'].Value
        Prerelease = $(if ($match.Groups['pre'].Success) { @($match.Groups['pre'].Value.Split('.')) } else { [string[]]@() })
    }
}

function Compare-DeskPetSemVer {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )
    $leftVersion = ConvertFrom-DeskPetSemVer $Left
    $rightVersion = ConvertFrom-DeskPetSemVer $Right
    foreach ($name in @('Major', 'Minor', 'Patch')) {
        if ($leftVersion.$name -lt $rightVersion.$name) { return -1 }
        if ($leftVersion.$name -gt $rightVersion.$name) { return 1 }
    }
    $leftPre = @($leftVersion.Prerelease)
    $rightPre = @($rightVersion.Prerelease)
    if (-not $leftPre.Count -and -not $rightPre.Count) { return 0 }
    if (-not $leftPre.Count) { return 1 }
    if (-not $rightPre.Count) { return -1 }
    $count = [Math]::Max($leftPre.Count, $rightPre.Count)
    for ($index = 0; $index -lt $count; $index++) {
        if ($index -ge $leftPre.Count) { return -1 }
        if ($index -ge $rightPre.Count) { return 1 }
        $leftPart = [string]$leftPre[$index]
        $rightPart = [string]$rightPre[$index]
        $leftNumeric = $leftPart -match '^\d+$'
        $rightNumeric = $rightPart -match '^\d+$'
        if ($leftNumeric -and $rightNumeric) {
            $leftNumber = $leftPart.TrimStart('0'); if (-not $leftNumber) { $leftNumber = '0' }
            $rightNumber = $rightPart.TrimStart('0'); if (-not $rightNumber) { $rightNumber = '0' }
            if ($leftNumber.Length -lt $rightNumber.Length) { return -1 }
            if ($leftNumber.Length -gt $rightNumber.Length) { return 1 }
            $numericComparison = [string]::CompareOrdinal($leftNumber, $rightNumber)
            if ($numericComparison -lt 0) { return -1 }
            if ($numericComparison -gt 0) { return 1 }
            continue
        }
        if ($leftNumeric -and -not $rightNumeric) { return -1 }
        if (-not $leftNumeric -and $rightNumeric) { return 1 }
        $comparison = [string]::CompareOrdinal($leftPart, $rightPart)
        if ($comparison -lt 0) { return -1 }
        if ($comparison -gt 0) { return 1 }
    }
    return 0
}

function Assert-DeskPetUpgradeIdentity {
    param(
        [Parameter(Mandatory)][string]$PreviousVersion,
        [Parameter(Mandatory)][string]$CurrentVersion,
        [Parameter(Mandatory)][string]$PreviousIdentifier,
        [Parameter(Mandatory)][string]$CurrentIdentifier,
        [Parameter(Mandatory)][string]$PreviousPublicKeyFingerprint,
        [Parameter(Mandatory)][string]$CurrentPublicKeyFingerprint
    )
    if ((Compare-DeskPetSemVer -Left $PreviousVersion -Right $CurrentVersion) -ge 0) {
        throw "Upgrade versions must satisfy previous < current: previous=$PreviousVersion; current=$CurrentVersion"
    }
    if ([string]::IsNullOrWhiteSpace($PreviousIdentifier) -or $PreviousIdentifier -ne $CurrentIdentifier) {
        throw "Upgrade identifier mismatch: previous=$PreviousIdentifier; current=$CurrentIdentifier"
    }
    if ([string]::IsNullOrWhiteSpace($PreviousPublicKeyFingerprint) -or $PreviousPublicKeyFingerprint -ne $CurrentPublicKeyFingerprint) {
        throw 'Upgrade updater public-key fingerprint mismatch.'
    }
}

function Get-DeskPetStringSha256 {
    param([Parameter(Mandatory)][string]$Value)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return -join @($algorithm.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    } finally { $algorithm.Dispose() }
}

function Get-UpdaterPublicKeyFingerprint {
    param([Parameter(Mandatory)][string]$PublicKeyPath)
    if (-not [System.IO.File]::Exists($PublicKeyPath)) { throw 'Updater public key file does not exist.' }
    $publicKeyText = [System.IO.File]::ReadAllText($PublicKeyPath, [System.Text.Encoding]::UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($publicKeyText)) { throw 'Updater public key file is empty.' }
    return Get-DeskPetStringSha256 -Value $publicKeyText
}

function Test-DeskPetUpdaterArtifactSignature {
    param(
        [Parameter(Mandatory)][string]$ArtifactPath,
        [Parameter(Mandatory)][string]$SignaturePath,
        [Parameter(Mandatory)][string]$PublicKeyPath,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 120
    )
    $toolingCommonPath = [System.IO.Path]::Combine($script:RepositoryRoot, 'scripts', 'updater', 'common.ps1')
    if (-not [System.IO.File]::Exists($toolingCommonPath)) { throw 'Updater verification tooling is missing.' }
    return [bool](& {
        param($CommonPath, $Artifact, $Signature, $PublicKey, $Timeout)
        . $CommonPath
        Test-UpdaterArtifactSignature -ArtifactPath $Artifact -SignaturePath $Signature -PublicKeyPath $PublicKey -TimeoutSeconds $Timeout
    } $toolingCommonPath $ArtifactPath $SignaturePath $PublicKeyPath $TimeoutSeconds)
}

function Get-DeskPetUpdaterManifestPath {
    param(
        [Parameter(Mandatory)][string]$ReleaseDirectory,
        [Parameter(Mandatory)][string]$Version
    )
    $preferred = [System.IO.Path]::Combine($ReleaseDirectory, 'updater', $Version, 'updater-release-manifest.json')
    if ([System.IO.File]::Exists($preferred)) { return $preferred }
    $updaterRoot = [System.IO.Path]::Combine($ReleaseDirectory, 'updater')
    if (-not [System.IO.Directory]::Exists($updaterRoot)) { return $null }
    foreach ($candidate in @(Get-ChildItem -LiteralPath $updaterRoot -Filter 'updater-release-manifest.json' -File -Recurse -ErrorAction SilentlyContinue)) {
        try {
            $parsed = Get-Content -LiteralPath $candidate.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string](Get-ObjectPropertyValue $parsed 'version') -eq $Version) { return $candidate.FullName }
        } catch { continue }
    }
    return $null
}

function Get-DeskPetUpdaterReadiness {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$ReleaseDirectory,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )
    $updaterRoot = [System.IO.Path]::Combine($ReleaseDirectory, 'updater')
    $overlayPath = [System.IO.Path]::Combine($RepositoryRoot, 'src-tauri', 'tauri.updater.conf.json')
    $buildOverlayEnabled = $false
    if ([System.IO.File]::Exists($overlayPath)) {
        try {
            $overlay = Get-Content -LiteralPath $overlayPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $overlayBundle = Get-ObjectPropertyValue $overlay 'bundle'
            $buildOverlayEnabled = [bool](Get-ObjectPropertyValue $overlayBundle 'createUpdaterArtifacts')
        } catch { $buildOverlayEnabled = $false }
    }
    $latestPath = [System.IO.Path]::Combine($updaterRoot, 'latest.json')
    $manifestPath = Get-DeskPetUpdaterManifestPath -ReleaseDirectory $ReleaseDirectory -Version $ExpectedVersion
    $hasAnyReleaseEvidence = [System.IO.File]::Exists($latestPath) -or
        -not [string]::IsNullOrWhiteSpace($manifestPath) -or
        ([System.IO.Directory]::Exists($updaterRoot) -and @(Get-ChildItem -LiteralPath $updaterRoot -File -Recurse -ErrorAction SilentlyContinue).Count -gt 0)
    $checks = @()
    if (-not $hasAnyReleaseEvidence) {
        return [pscustomobject]@{
            State = 'NOT_CONFIGURED'; Ready = $false; Checks = @(); ManifestPath = $null
            LatestPath = $latestPath; ArtifactPath = $null; SignaturePath = $null
            PublicKeyFingerprint = $null; Endpoint = $null; BuildOverlayEnabled = $buildOverlayEnabled
        }
    }

    $manifest = $null
    if (-not [string]::IsNullOrWhiteSpace($manifestPath)) {
        try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $manifest = $null }
    }
    $manifestVersion = [string](Get-ObjectPropertyValue $manifest 'version')
    $currentVersion = [string](Get-ObjectPropertyValue $manifest 'currentVersion')
    $identifier = [string](Get-ObjectPropertyValue $manifest 'identifier')
    $fingerprint = [string](Get-ObjectPropertyValue $manifest 'publicKeyFingerprint')
    if ([string]::IsNullOrWhiteSpace($fingerprint)) { $fingerprint = [string](Get-ObjectPropertyValue $manifest 'updaterPublicKeyFingerprint') }
    $endpoint = [string](Get-ObjectPropertyValue $manifest 'endpoint')
    if ([string]::IsNullOrWhiteSpace($endpoint)) { $endpoint = [string](Get-ObjectPropertyValue $manifest 'endpointUrl') }
    $installMode = [string](Get-ObjectPropertyValue $manifest 'installMode')
    $artifactFile = [string](Get-ObjectPropertyValue $manifest 'artifactFile')
    if ([string]::IsNullOrWhiteSpace($artifactFile)) { $artifactFile = [string](Get-ObjectPropertyValue $manifest 'updaterArtifactFile') }
    $signatureFile = [string](Get-ObjectPropertyValue $manifest 'signatureFile')
    if ([string]::IsNullOrWhiteSpace($signatureFile)) { $signatureFile = [string](Get-ObjectPropertyValue $manifest 'updaterSignatureFile') }
    $artifactSha256 = [string](Get-ObjectPropertyValue $manifest 'artifactSha256')
    if ([string]::IsNullOrWhiteSpace($artifactSha256)) { $artifactSha256 = [string](Get-ObjectPropertyValue $manifest 'sha256') }
    $signatureSha256 = [string](Get-ObjectPropertyValue $manifest 'signatureSha256')
    $latestJsonSha256 = [string](Get-ObjectPropertyValue $manifest 'latestJsonSha256')
    $downloadUrl = [string](Get-ObjectPropertyValue $manifest 'downloadUrl')
    $updaterGitCommit = [string](Get-ObjectPropertyValue $manifest 'gitCommit')
    $updaterDirtyWorktreeValue = Get-ObjectPropertyValue $manifest 'dirtyWorktree'
    $updaterDirtyWorktree = [bool]$updaterDirtyWorktreeValue
    $updaterCleanWorktree = $null -ne $updaterDirtyWorktreeValue -and -not $updaterDirtyWorktree
    $manifestDirectory = if ([string]::IsNullOrWhiteSpace($manifestPath)) { [System.IO.Path]::Combine($updaterRoot, $ExpectedVersion) } else { [System.IO.Path]::GetDirectoryName($manifestPath) }
    $artifactPath = if ([string]::IsNullOrWhiteSpace($artifactFile)) { $null } else { [System.IO.Path]::Combine($manifestDirectory, $artifactFile) }
    $signaturePath = if ([string]::IsNullOrWhiteSpace($signatureFile)) { $null } else { [System.IO.Path]::Combine($manifestDirectory, $signatureFile) }

    $latest = $null
    if ([System.IO.File]::Exists($latestPath)) {
        try { $latest = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $latest = $null }
    }
    $latestVersion = [string](Get-ObjectPropertyValue $latest 'version')
    $platforms = Get-ObjectPropertyValue $latest 'platforms'
    $windowsPlatform = $null
    if ($null -ne $platforms) {
        foreach ($property in $platforms.PSObject.Properties) {
            if ($property.Name -match '^windows-(x86_64|aarch64|i686)$') { $windowsPlatform = $property.Value; break }
        }
    }
    $latestUrl = [string](Get-ObjectPropertyValue $windowsPlatform 'url')
    $latestSignature = [string](Get-ObjectPropertyValue $windowsPlatform 'signature')
    $latestArtifactSize = 0L
    $latestSizeValue = Get-ObjectPropertyValue $windowsPlatform 'size'
    $latestSizeValid = $null -ne $latestSizeValue -and [long]::TryParse([string]$latestSizeValue, [ref]$latestArtifactSize) -and $latestArtifactSize -gt 0
    $signatureText = if ($signaturePath -and [System.IO.File]::Exists($signaturePath)) { [System.IO.File]::ReadAllText($signaturePath, [System.Text.Encoding]::UTF8).Trim() } else { $null }
    $signatureMatchesLatest = -not [string]::IsNullOrWhiteSpace($signatureText) -and [string]::Equals($signatureText, $latestSignature, [StringComparison]::Ordinal)
    $downloadUrlMatchesLatest = -not [string]::IsNullOrWhiteSpace($downloadUrl) -and [string]::Equals($downloadUrl, $latestUrl, [StringComparison]::Ordinal)
    $actualArtifactHash = if ($artifactPath -and [System.IO.File]::Exists($artifactPath)) { (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash } else { $null }
    $actualArtifactSize = if ($artifactPath -and [System.IO.File]::Exists($artifactPath)) { (Get-Item -LiteralPath $artifactPath).Length } else { 0L }
    $actualSignatureHash = if ($signaturePath -and [System.IO.File]::Exists($signaturePath)) { (Get-FileHash -LiteralPath $signaturePath -Algorithm SHA256).Hash } else { $null }
    $actualLatestHash = if ([System.IO.File]::Exists($latestPath)) { (Get-FileHash -LiteralPath $latestPath -Algorithm SHA256).Hash } else { $null }
    $latestHasBom = $false
    if ([System.IO.File]::Exists($latestPath)) {
        $latestBytes = [System.IO.File]::ReadAllBytes($latestPath)
        $latestHasBom = $latestBytes.Length -ge 3 -and $latestBytes[0] -eq 0xEF -and $latestBytes[1] -eq 0xBB -and $latestBytes[2] -eq 0xBF
    }
    $signatureIsBase64 = $false
    if (-not [string]::IsNullOrWhiteSpace($signatureText)) {
        try { [void][Convert]::FromBase64String($signatureText); $signatureIsBase64 = $true } catch { $signatureIsBase64 = $false }
    }
    $versionIncrease = $false
    try { $versionIncrease = (Compare-DeskPetSemVer -Left $currentVersion -Right $manifestVersion) -lt 0 } catch { $versionIncrease = $false }
    $releaseManifestPath = [System.IO.Path]::Combine($ReleaseDirectory, 'release-manifest.json')
    $releaseManifestCommit = $null
    if ([System.IO.File]::Exists($releaseManifestPath)) {
        try {
            $releaseManifestDocument = Get-Content -LiteralPath $releaseManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $releaseManifestCommit = [string](Get-ObjectPropertyValue $releaseManifestDocument 'gitCommit')
        } catch { $releaseManifestCommit = $null }
    }
    $headCommit = (& git -C $RepositoryRoot rev-parse HEAD 2>$null)
    $headCommit = if ($LASTEXITCODE -eq 0 -and $headCommit) { ([string]$headCommit).Trim() } else { $null }
    $httpsEndpoint = $false
    $endpointUri = $null
    if (-not [string]::IsNullOrWhiteSpace($endpoint)) {
        try { $endpointUri = [uri]$endpoint; $httpsEndpoint = $endpointUri.IsAbsoluteUri -and $endpointUri.Scheme -eq 'https' } catch { $httpsEndpoint = $false }
    }
    $httpsLatest = $false
    $latestUri = $null
    if (-not [string]::IsNullOrWhiteSpace($latestUrl)) {
        try { $latestUri = [uri]$latestUrl; $httpsLatest = $latestUri.IsAbsoluteUri -and $latestUri.Scheme -eq 'https' } catch { $httpsLatest = $false }
    }
    $urlArtifactName = if ($null -ne $latestUri) { [Uri]::UnescapeDataString([System.IO.Path]::GetFileName($latestUri.AbsolutePath)) } else { $null }
    $artifactVersionPattern = '(?<![0-9A-Za-z])' + [regex]::Escape($ExpectedVersion) + '(?![0-9A-Za-z])'
    $artifactBindingValid = -not [string]::IsNullOrWhiteSpace($artifactFile) -and $artifactFile -match $artifactVersionPattern -and
        [string]::Equals($urlArtifactName, $artifactFile, [StringComparison]::Ordinal) -and $latestSizeValid -and $latestArtifactSize -eq $actualArtifactSize
    $signatureBindingValid = -not [string]::IsNullOrWhiteSpace($signatureFile) -and [string]::Equals($signatureFile, $artifactFile + '.sig', [StringComparison]::Ordinal)
    $checks = @(
        [pscustomobject]@{ Name='Updater build overlay'; Passed=$buildOverlayEnabled; Details='src-tauri/tauri.updater.conf.json createUpdaterArtifacts=true' },
        [pscustomobject]@{ Name='Updater release manifest'; Passed=$null -ne $manifest; Details=$(if($manifestPath){'updater/<version>/updater-release-manifest.json'}else{'missing'}) },
        [pscustomobject]@{ Name='Updater version'; Passed=$manifestVersion -eq $ExpectedVersion -and $latestVersion -eq $ExpectedVersion; Details="manifest=$manifestVersion; latest=$latestVersion; expected=$ExpectedVersion" },
        [pscustomobject]@{ Name='Updater strict version increase'; Passed=$versionIncrease; Details="current=$currentVersion; target=$manifestVersion" },
        [pscustomobject]@{ Name='Updater identifier'; Passed=$identifier -eq $script:AppIdentifier; Details=$identifier },
        [pscustomobject]@{ Name='Updater public-key fingerprint'; Passed=-not [string]::IsNullOrWhiteSpace($fingerprint); Details=$(if($fingerprint){$fingerprint}else{'missing'}) },
        [pscustomobject]@{ Name='Updater HTTPS endpoint'; Passed=$httpsEndpoint; Details=$(if($endpointUri){$endpointUri.DnsSafeHost}else{'missing or invalid'}) },
        [pscustomobject]@{ Name='Updater Windows install mode'; Passed=$installMode -eq 'passive'; Details=$(if($installMode){$installMode}else{'missing'}) },
        [pscustomobject]@{ Name='Updater latest JSON'; Passed=$null -ne $latest -and $null -ne $windowsPlatform -and $httpsLatest -and -not $latestHasBom; Details=$(if([System.IO.File]::Exists($latestPath)){'updater/latest.json'}else{'missing'}) },
        [pscustomobject]@{ Name='Updater download URL binding'; Passed=$downloadUrlMatchesLatest; Details=$(if($latestUrl){$latestUrl}else{'missing'}) },
        [pscustomobject]@{ Name='Updater artifact URL and size binding'; Passed=$artifactBindingValid; Details="name=$(if($artifactFile){$artifactFile}else{'missing'}); size=$actualArtifactSize" },
        [pscustomobject]@{ Name='Updater signature filename binding'; Passed=$signatureBindingValid; Details=$(if($signatureFile){$signatureFile}else{'missing'}) },
        [pscustomobject]@{ Name='Updater artifact'; Passed=$artifactPath -and [System.IO.File]::Exists($artifactPath); Details=$(if($artifactFile){$artifactFile}else{'missing'}) },
        [pscustomobject]@{ Name='Updater artifact hash'; Passed=-not [string]::IsNullOrWhiteSpace($actualArtifactHash) -and $actualArtifactHash -eq $artifactSha256; Details=$(if($actualArtifactHash){$actualArtifactHash}else{'missing'}) },
        [pscustomobject]@{ Name='Updater detached signature'; Passed=$signatureIsBase64 -and $signatureMatchesLatest; Details=$(if($signatureFile){$signatureFile}else{'missing'}) },
        [pscustomobject]@{ Name='Updater metadata hashes'; Passed=$actualSignatureHash -eq $signatureSha256 -and $actualLatestHash -eq $latestJsonSha256; Details="signature=$actualSignatureHash; latest=$actualLatestHash" },
        [pscustomobject]@{ Name='Updater commit binding'; Passed=-not [string]::IsNullOrWhiteSpace($updaterGitCommit) -and $updaterGitCommit -eq $releaseManifestCommit -and $updaterGitCommit -eq $headCommit; Details="updater=$updaterGitCommit; release=$releaseManifestCommit; head=$headCommit" }
        [pscustomobject]@{ Name='Updater clean worktree'; Passed=$updaterCleanWorktree; Details="dirty=$(if($null -eq $updaterDirtyWorktreeValue){'missing'}else{$updaterDirtyWorktree})" }
    )
    $ready = @($checks | Where-Object { -not $_.Passed }).Count -eq 0
    [pscustomobject]@{
        State = $(if ($ready) { 'READY' } else { 'MISCONFIGURED' }); Ready = $ready; Checks = $checks
        ManifestPath = $manifestPath; LatestPath = $latestPath; ArtifactPath = $artifactPath; SignaturePath = $signaturePath
        PublicKeyFingerprint = $fingerprint; Endpoint = $endpoint; BuildOverlayEnabled = $buildOverlayEnabled
    }
}

function Test-DeskPetPublicBetaEvidence {
    param(
        [Parameter(Mandatory)][object]$Environment,
        [Parameter(Mandatory)][string]$ExpectedCommit,
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [Parameter(Mandatory)][string]$ExpectedInstallerSha256
    )
    $reasons = @()
    if (-not (Test-DeskPetSchemaVersionOne -InputObject $Environment)) {
        $reasons += 'schemaVersion must be the JSON integer 1'
    }
    $commit = [string](Get-ObjectPropertyValue $Environment 'gitCommit')
    $version = [string](Get-ObjectPropertyValue $Environment 'expectedVersion')
    $artifact = Get-ObjectPropertyValue $Environment 'artifact'
    $sha256 = [string](Get-ObjectPropertyValue $artifact 'installerSha256')
    if ($commit -ne $ExpectedCommit) { $reasons += "gitCommit=$commit does not match $ExpectedCommit" }
    if ($version -ne $ExpectedVersion) { $reasons += "expectedVersion=$version does not match $ExpectedVersion" }
    if ($sha256 -ne $ExpectedInstallerSha256) { $reasons += "installerSha256=$sha256 does not match current Release" }
    [pscustomobject]@{ Valid=$reasons.Count -eq 0; Reasons=@($reasons) }
}

function Get-DeskPetCurrentMachinePhasePlan {
    param([switch]$UseExistingInstallation)
    if ($UseExistingInstallation) { return @('post-install-validation', 'uninstallation', 'post-uninstall-cleanup') }
    return @('installation', 'post-install-validation', 'uninstallation', 'post-uninstall-cleanup')
}

function ConvertTo-NormalizedProcessorArchitecture {
    param([AllowNull()][string]$Architecture)
    if ([string]::IsNullOrWhiteSpace($Architecture)) { return $null }
    switch ($Architecture.ToUpperInvariant()) {
        'AMD64' { return 'x64' }
        'X86' { return 'x86' }
        'ARM64' { return 'arm64' }
        default { return $Architecture.ToLowerInvariant() }
    }
}

function Get-NativeProcessorArchitecture {
    param(
        [AllowNull()][string]$ArchitectureW6432 = $env:PROCESSOR_ARCHITEW6432,
        [AllowNull()][string]$Architecture = $env:PROCESSOR_ARCHITECTURE,
        [Nullable[bool]]$Is64BitOperatingSystem = $null
    )
    $native = $ArchitectureW6432
    if ([string]::IsNullOrWhiteSpace($native)) { $native = $Architecture }
    if ([string]::IsNullOrWhiteSpace($native)) {
        $osIs64Bit = if ($null -eq $Is64BitOperatingSystem) { [System.Environment]::Is64BitOperatingSystem } else { [bool]$Is64BitOperatingSystem }
        $native = if ($osIs64Bit) { 'AMD64' } else { 'x86' }
    }
    ConvertTo-NormalizedProcessorArchitecture $native
}

function Get-CurrentProcessArchitecture {
    param(
        [AllowNull()][string]$Architecture = $env:PROCESSOR_ARCHITECTURE,
        [Nullable[bool]]$Is64BitProcess = $null
    )
    if (-not [string]::IsNullOrWhiteSpace($Architecture)) {
        return ConvertTo-NormalizedProcessorArchitecture $Architecture
    }
    $processIs64Bit = if ($null -eq $Is64BitProcess) { [System.Environment]::Is64BitProcess } else { [bool]$Is64BitProcess }
    if ($processIs64Bit) { return Get-NativeProcessorArchitecture }
    return 'x86'
}

function Get-QAOperatingSystemFacts {
    param(
        [scriptblock]$CimQuery = { Get-CimInstance Win32_OperatingSystem -ErrorAction Stop }
    )

    $record = $null
    try {
        $record = @(& $CimQuery)[0]
    } catch {
        $record = $null
    }

    if ($null -ne $record) {
        return [ordered]@{
            Caption=[string](Get-ObjectPropertyValue $record 'Caption')
            Version=[string](Get-ObjectPropertyValue $record 'Version')
            BuildNumber=[string](Get-ObjectPropertyValue $record 'BuildNumber')
            OSArchitecture=[string](Get-ObjectPropertyValue $record 'OSArchitecture')
            source='cim'
        }
    }

    return [ordered]@{
        Caption=[Environment]::OSVersion.VersionString
        Version=[Environment]::OSVersion.Version.ToString()
        BuildNumber=[Environment]::OSVersion.Version.Build.ToString()
        OSArchitecture=Get-NativeProcessorArchitecture
        source='environment-fallback'
    }
}

function Get-QAExecutableSearchPath {
    param(
        [AllowNull()][string]$ProcessPath = [Environment]::GetEnvironmentVariable('Path', 'Process'),
        [AllowNull()][string]$UserPath = [Environment]::GetEnvironmentVariable('Path', 'User'),
        [AllowNull()][string]$MachinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    )

    return (@($ProcessPath, $UserPath, $MachinePath) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [System.IO.Path]::PathSeparator
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-DeskPetSchemaVersionOne {
    param([Parameter(Mandatory)][AllowNull()][object]$InputObject)
    $value = Get-ObjectPropertyValue $InputObject 'schemaVersion'
    $isJsonInteger = $value -is [System.Int32] -or $value -is [System.Int64] -or
        $value -is [System.Int16] -or $value -is [System.Byte]
    return $isJsonInteger -and [System.Int64]$value -eq 1
}

function Join-NativeFileSystemPath {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$BasePath,
        [Parameter(Mandatory)][string]$ChildPath
    )
    $expanded = [Environment]::ExpandEnvironmentVariables($BasePath).Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($expanded)) { throw 'InstallLocation is empty.' }
    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        throw "InstallLocation is not an absolute path: $expanded"
    }
    try {
        return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($expanded, $ChildPath))
    } catch {
        throw "InstallLocation is not a valid native path: $expanded"
    }
}

function ConvertTo-RedactedNativePath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '<empty>' }
    $redacted = [Environment]::ExpandEnvironmentVariables($Path).Trim().Trim('"')
    $locations = @(
        @{ Value=$env:LOCALAPPDATA; Token='%LOCALAPPDATA%' },
        @{ Value=$env:APPDATA; Token='%APPDATA%' },
        @{ Value=$env:USERPROFILE; Token='%USERPROFILE%' },
        @{ Value=$env:ProgramFiles; Token='%ProgramFiles%' },
        @{ Value=${env:ProgramFiles(x86)}; Token='%ProgramFiles(x86)%' }
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Value) } |
        Sort-Object { ([string]$_.Value).Length } -Descending
    foreach ($location in $locations) {
        $prefix = ([string]$location.Value).TrimEnd('\')
        if ($redacted.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return [string]$location.Token + $redacted.Substring($prefix.Length)
        }
    }
    if ($redacted -match '^[A-Za-z]:\\Users\\[^\\]+(?<rest>\\.*)?$') {
        return '%USERPROFILE%' + [string]$Matches['rest']
    }
    return $redacted
}

function Get-DeskPetReleaseVersion {
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $configPath = [System.IO.Path]::Combine($RepositoryRoot, 'src-tauri', 'tauri.conf.json')
    if (-not [System.IO.File]::Exists($configPath)) { throw "Tauri configuration not found: $configPath" }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    return [string](Get-ObjectPropertyValue -InputObject $config -Name 'version')
}

function Get-DeskPetReleaseInstaller {
    param(
        [string]$ReleaseDirectory = [System.IO.Path]::Combine($script:RepositoryRoot, 'release')
    )
    if (-not [System.IO.Directory]::Exists($ReleaseDirectory)) { return $null }

    $manifestPath = [System.IO.Path]::Combine($ReleaseDirectory, 'release-manifest.json')
    if ([System.IO.File]::Exists($manifestPath)) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $versionedFile = [string](Get-ObjectPropertyValue -InputObject $manifest -Name 'versionedInstallerFile')
            if (-not [string]::IsNullOrWhiteSpace($versionedFile)) {
                $manifestInstaller = [System.IO.Path]::Combine($ReleaseDirectory, $versionedFile)
                if ([System.IO.File]::Exists($manifestInstaller)) { return Get-Item -LiteralPath $manifestInstaller }
            }
        } catch {
            Write-Warning 'The release manifest could not be read; falling back to a branded installer filename match.'
        }
    }

    $prefix = "$script:ProductName`_"
    return Get-ChildItem -LiteralPath $ReleaseDirectory -Filter '*-setup.exe' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

function Select-DeskPetInstallRecord {
    param(
        [AllowEmptyCollection()][object[]]$Records = @(),
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [string]$ExecutableName = $script:ExecutableName,
        [scriptblock]$DirectoryExists = { param($Path) [System.IO.Directory]::Exists($Path) },
        [scriptblock]$FileExists = { param($Path) [System.IO.File]::Exists($Path) }
    )
    $evaluations = @()
    foreach ($record in @($Records)) {
        $displayName = [string](Get-ObjectPropertyValue $record 'DisplayName')
        $displayVersion = [string](Get-ObjectPropertyValue $record 'DisplayVersion')
        $installLocation = [string](Get-ObjectPropertyValue $record 'InstallLocation')
        $psPath = [string](Get-ObjectPropertyValue $record 'PSPath')
        $reasons = @()
        $executablePath = $null
        $normalizedDirectory = $null
        if ($displayName -ne $script:ProductName) { $reasons += 'DisplayName is not an exact match.' }
        if ($displayVersion -ne $ExpectedVersion) { $reasons += "DisplayVersion does not match $ExpectedVersion." }
        try {
            $executablePath = Join-NativeFileSystemPath -BasePath $installLocation -ChildPath $ExecutableName
            $normalizedDirectory = [System.IO.Path]::GetDirectoryName($executablePath)
            if (-not (& $DirectoryExists $normalizedDirectory)) { $reasons += 'InstallLocation directory does not exist or is unavailable.' }
            if (-not (& $FileExists $executablePath)) { $reasons += 'Main executable does not exist.' }
        } catch {
            $reasons += $_.Exception.Message
        }
        $evaluations += [pscustomobject]@{
            Record=$record
            DisplayName=$displayName
            DisplayVersion=$displayVersion
            RedactedInstallLocation=ConvertTo-RedactedNativePath $installLocation
            InstallDirectory=$normalizedDirectory
            ExecutablePath=$executablePath
            CurrentUser=($psPath -match 'HKEY_CURRENT_USER|HKCU:')
            Usable=($reasons.Count -eq 0)
            Reasons=@($reasons)
        }
    }
    $selected = @($evaluations | Where-Object { $_.Usable } | Sort-Object @{Expression='CurrentUser';Descending=$true}) | Select-Object -First 1
    [pscustomobject]@{
        SelectedRecord=$(if ($selected) { $selected.Record } else { $null })
        ExecutablePath=$(if ($selected) { $selected.ExecutablePath } else { $null })
        Evaluation=$(if ($selected) { $selected } else { $null })
        Evaluations=@($evaluations)
    }
}

function Get-NoAvailableUninstallCommandMessage {
    return -join @([char]0x6CA1,[char]0x6709,[char]0x53EF,[char]0x7528,[char]0x5378,[char]0x8F7D,[char]0x547D,[char]0x4EE4)
}

function ConvertFrom-NativeCommandLine {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { throw (Get-NoAvailableUninstallCommandMessage) }
    $expanded = [Environment]::ExpandEnvironmentVariables($CommandLine).Trim()
    $filePath = $null
    $argumentText = $null
    if ($expanded -match '^"(?<file>[^"]+)"(?:\s+(?<arguments>.*))?$') {
        $filePath = [string]$Matches['file']
        $argumentText = [string]$Matches['arguments']
    } elseif ($expanded -match '^(?<file>.+?\.exe)(?:\s+(?<arguments>.*))?$') {
        $filePath = ([string]$Matches['file']).Trim()
        $argumentText = [string]$Matches['arguments']
    } else {
        throw 'The uninstall command format cannot be parsed safely.'
    }
    if ([string]::IsNullOrWhiteSpace($filePath) -or -not [System.IO.Path]::IsPathRooted($filePath)) {
        throw 'The uninstaller path is not a valid absolute path.'
    }
    try { $filePath = [System.IO.Path]::GetFullPath($filePath) } catch { throw 'The uninstaller path format is invalid.' }
    if ([string]::IsNullOrWhiteSpace($argumentText)) { $argumentList = [string[]]@() }
    else { $argumentList = [string[]]@($argumentText.Trim()) }
    [pscustomobject]@{ FilePath=$filePath; ArgumentList=$argumentList }
}

function Resolve-DeskPetUninstallCommand {
    param(
        [Parameter(Mandatory)][object]$Record,
        [scriptblock]$FileExists = { param($Path) [System.IO.File]::Exists($Path) }
    )
    $candidates = @(
        [pscustomobject]@{ Source='QuietUninstallString'; Value=[string](Get-ObjectPropertyValue $Record 'QuietUninstallString') },
        [pscustomobject]@{ Source='UninstallString'; Value=[string](Get-ObjectPropertyValue $Record 'UninstallString') }
    )
    $errors = @()
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate.Value)) { continue }
        try {
            $parsed = ConvertFrom-NativeCommandLine -CommandLine $candidate.Value
            if (-not (& $FileExists $parsed.FilePath)) {
                $errors += "$($candidate.Source) points to a missing or unavailable executable."
                continue
            }
            return [pscustomobject]@{
                Source=$candidate.Source
                FilePath=$parsed.FilePath
                ArgumentList=$parsed.ArgumentList
                RedactedFilePath=ConvertTo-RedactedNativePath $parsed.FilePath
            }
        } catch {
            $errors += "$($candidate.Source): $($_.Exception.Message)"
        }
    }
    if ($errors.Count) { throw ((Get-NoAvailableUninstallCommandMessage) + ': ' + ($errors -join ' ')) }
    throw (Get-NoAvailableUninstallCommandMessage)
}

function Select-DeskPetUninstallRecord {
    param(
        [AllowEmptyCollection()][object[]]$Records = @(),
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [scriptblock]$FileExists = { param($Path) [System.IO.File]::Exists($Path) }
    )
    $evaluations = @()
    foreach ($record in @($Records)) {
        $displayName = [string](Get-ObjectPropertyValue $record 'DisplayName')
        $displayVersion = [string](Get-ObjectPropertyValue $record 'DisplayVersion')
        $psPath = [string](Get-ObjectPropertyValue $record 'PSPath')
        $reasons = @()
        $command = $null
        if ($displayName -ne $script:ProductName) { $reasons += 'DisplayName is not an exact match.' }
        if ($displayVersion -ne $ExpectedVersion) { $reasons += "DisplayVersion does not match $ExpectedVersion." }
        try { $command = Resolve-DeskPetUninstallCommand -Record $record -FileExists $FileExists } catch { $reasons += $_.Exception.Message }
        $evaluations += [pscustomobject]@{
            Record=$record; DisplayName=$displayName; DisplayVersion=$displayVersion; Command=$command
            CurrentUser=($psPath -match 'HKEY_CURRENT_USER|HKCU:'); Usable=($reasons.Count -eq 0); Reasons=@($reasons)
        }
    }
    $selected = @($evaluations | Where-Object { $_.Usable } | Sort-Object @{Expression='CurrentUser';Descending=$true}) | Select-Object -First 1
    [pscustomobject]@{
        SelectedRecord=$(if ($selected) { $selected.Record } else { $null })
        Command=$(if ($selected) { $selected.Command } else { $null })
        Evaluation=$(if ($selected) { $selected } else { $null })
        Evaluations=@($evaluations)
    }
}

function Write-QAResultArtifacts {
    param(
        [Parameter(Mandatory)][string]$OutputDirectory,
        [AllowEmptyCollection()][object[]]$Results = @(),
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Phase,
        [AllowNull()][string]$FailureMessage,
        [AllowNull()][object]$Transaction
    )
    $savedWhatIfPreference = $WhatIfPreference
    $WhatIfPreference = $false
    try {
        [System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
        ConvertTo-Json -InputObject @($Results) -Depth 10 | Set-Content -Encoding UTF8 -LiteralPath ([System.IO.Path]::Combine($OutputDirectory, 'qa-results.json'))
        if ($null -ne $Transaction) {
            $Transaction | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -LiteralPath ([System.IO.Path]::Combine($OutputDirectory, 'current-machine-state.json'))
        }
    $passed = @($Results | Where-Object { $_.status -eq 'passed' })
    $failed = @($Results | Where-Object { $_.status -eq 'failed' })
    $blocked = @($Results | Where-Object { $_.status -eq 'blocked' })
    $skipped = @($Results | Where-Object { $_.status -eq 'skipped' })
    $summary = @(
        '# Windows QA summary', '', "- Mode: $Mode", "- Final phase: $Phase",
        "- Generated UTC: $([DateTime]::UtcNow.ToString('o'))", "- Failure: $(if ($FailureMessage) { $FailureMessage } else { 'none' })", '',
        "## Passed ($($passed.Count))", ''
    ) + @($passed | ForEach-Object { "- $($_.name)" }) + @('', "## Failed ($($failed.Count))", '') +
        @($failed | ForEach-Object { "- $($_.name): $($_.details)" }) + @('', "## Blocked ($($blocked.Count))", '') +
        @($blocked | ForEach-Object { "- $($_.name): $($_.details)" }) + @('', '## Manual Windows checks', '',
        '- Real Windows 10/11, multi-monitor and DPI, sleep/wake, SmartScreen, tray interaction, and eight-hour performance testing.', '',
        "## Skipped ($($skipped.Count))", '') + @($skipped | ForEach-Object { "- $($_.name): $($_.details)" })
        ($summary -join [Environment]::NewLine) | Set-Content -Encoding UTF8 -LiteralPath ([System.IO.Path]::Combine($OutputDirectory, 'qa-summary.md'))
    } finally {
        $WhatIfPreference = $savedWhatIfPreference
    }
}

function Get-DeskPetInstallRecords {
    param([switch]$IncludeLegacy)
    $displayNames = @($script:ProductName)
    if ($IncludeLegacy) { $displayNames += @($script:LegacyProductNames) }
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $roots) {
        Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['DisplayName'] -and $displayNames -contains [string]$_.DisplayName }
    }
}

function Test-DeskPetRunEntryMatch {
    param(
        [AllowEmptyString()][string]$Name,
        [AllowEmptyString()][string]$Value,
        [switch]$IncludeLegacy
    )
    $names = @($script:ProductName, $script:ExecutableName, $script:ProcessName)
    if ($IncludeLegacy) { $names += @($script:LegacyProductNames) + @($script:LegacyExecutableNames) + @($script:LegacyProcessNames) }
    return @($names | Where-Object {
        $Name.IndexOf([string]$_, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $Value.IndexOf([string]$_, [StringComparison]::OrdinalIgnoreCase) -ge 0
    }).Count -gt 0
}

function Get-DeskPetRunEntries {
    param([switch]$IncludeLegacy)
    $runKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($key in $runKeys) {
        $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        foreach ($property in $item.PSObject.Properties) {
            if ($property.Name -like 'PS*') { continue }
            $value = [string]$property.Value
            if (Test-DeskPetRunEntryMatch -Name $property.Name -Value $value -IncludeLegacy:$IncludeLegacy) {
                [pscustomobject]@{ Key = $key; Name = $property.Name; Value = $value }
            }
        }
    }
}

function Get-DeskPetStartMenuEntries {
    param([switch]$IncludeLegacy)
    $names = @($script:ProductName)
    if ($IncludeLegacy) { $names += @($script:LegacyProductNames) }
    $roots = @(
        [System.IO.Path]::Combine($env:APPDATA, 'Microsoft', 'Windows', 'Start Menu', 'Programs'),
        [Environment]::GetFolderPath('CommonStartMenu')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and [System.IO.Directory]::Exists([string]$_) }
    foreach ($root in $roots) {
        Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
            $entryName = $_.Name
            @($names | Where-Object { $entryName.IndexOf([string]$_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0
        }
    }
}

function Get-DeskPetRunningProcesses {
    param([switch]$IncludeLegacy)
    $processNames = @($script:ProcessName)
    if ($IncludeLegacy) { $processNames += @($script:LegacyProcessNames) }
    foreach ($processName in $processNames | Select-Object -Unique) {
        Get-Process -Name $processName -ErrorAction SilentlyContinue
    }
}

function Get-DeskPetUninstallCleanupState {
    param(
        [AllowNull()][AllowEmptyString()][string]$InstallLocation
    )
    $records = @(Get-DeskPetInstallRecords -IncludeLegacy)
    $processes = @(Get-DeskPetRunningProcesses -IncludeLegacy)
    $autostartEntries = @(Get-DeskPetRunEntries -IncludeLegacy)
    $startMenuEntries = @(Get-DeskPetStartMenuEntries -IncludeLegacy)
    $installDirectoryExists = -not [string]::IsNullOrWhiteSpace($InstallLocation) -and
        [System.IO.Directory]::Exists($InstallLocation)
    [pscustomobject]@{
        InstallRecordCount = $records.Count
        ProcessCount = $processes.Count
        AutostartEntryCount = $autostartEntries.Count
        StartMenuEntryCount = $startMenuEntries.Count
        InstallDirectoryExists = $installDirectoryExists
        RedactedInstallLocation = $(if ([string]::IsNullOrWhiteSpace($InstallLocation)) { '<empty>' } else { ConvertTo-RedactedNativePath $InstallLocation })
    }
}

function Wait-DeskPetUninstallCleanup {
    param(
        [AllowNull()][AllowEmptyString()][string]$InstallLocation,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 60,
        [ValidateRange(500, 1000)][int]$PollIntervalMilliseconds = 500,
        [scriptblock]$Probe = { param($Path) Get-DeskPetUninstallCleanupState -InstallLocation $Path },
        [scriptblock]$Delay = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds },
        [AllowNull()][scriptblock]$GetElapsedMilliseconds
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($null -eq $GetElapsedMilliseconds) {
        $GetElapsedMilliseconds = { $stopwatch.ElapsedMilliseconds }.GetNewClosure()
    }
    $timeoutMilliseconds = [int64]$TimeoutSeconds * 1000
    $attempts = 0
    while ($true) {
        $attempts++
        $state = & $Probe $InstallLocation
        $elapsedMilliseconds = [int64](& $GetElapsedMilliseconds)
        $complete = [int](Get-ObjectPropertyValue $state 'InstallRecordCount') -eq 0 -and
            [int](Get-ObjectPropertyValue $state 'ProcessCount') -eq 0 -and
            [int](Get-ObjectPropertyValue $state 'AutostartEntryCount') -eq 0 -and
            [int](Get-ObjectPropertyValue $state 'StartMenuEntryCount') -eq 0 -and
            -not [bool](Get-ObjectPropertyValue $state 'InstallDirectoryExists')
        if ($complete -or $elapsedMilliseconds -ge $timeoutMilliseconds) {
            $stopwatch.Stop()
            return [pscustomobject]@{
                Complete = $complete
                TimedOut = -not $complete
                ElapsedMilliseconds = $elapsedMilliseconds
                ElapsedSeconds = [Math]::Round($elapsedMilliseconds / 1000, 3)
                Attempts = $attempts
                State = $state
            }
        }
        $remainingMilliseconds = $timeoutMilliseconds - $elapsedMilliseconds
        $delayMilliseconds = [int][Math]::Min($PollIntervalMilliseconds, $remainingMilliseconds)
        & $Delay $delayMilliseconds
    }
}

function Write-SmokeResult {
    param([string]$Name, [bool]$Passed, [string]$Details)
    $status = if ($Passed) { 'PASS' } else { 'FAIL' }
    [pscustomobject]@{ Check = $Name; Status = $status; Details = $Details }
}

function Assert-FileExists {
    param([Parameter(Mandatory)][string]$LiteralPath, [string]$Label = 'File')
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "$Label not found: $LiteralPath"
    }
}
