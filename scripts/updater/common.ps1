Set-StrictMode -Version Latest

$script:UpdaterToolsDirectory = [System.IO.Path]::GetFullPath($PSScriptRoot)
$script:UpdaterRepositoryRoot = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::Combine($script:UpdaterToolsDirectory, '..', '..')
)
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Resolve-UpdaterPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BaseDirectory
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if ([string]::IsNullOrWhiteSpace($expanded)) { throw 'Path is empty.' }
    if ([string]::IsNullOrWhiteSpace($BaseDirectory) -or -not [System.IO.Path]::IsPathRooted($BaseDirectory)) {
        throw "BaseDirectory is not an absolute path: $BaseDirectory"
    }
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($BaseDirectory, $expanded))
}

function Test-PathWithinDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Directory
    )

    $candidate = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [System.IO.Path]::GetFullPath($Directory).TrimEnd('\', '/')
    if ([string]::Equals($candidate, $root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $candidate.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-UpdaterRedactedPath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '<empty>' }
    $value = [Environment]::ExpandEnvironmentVariables($Path).Trim().Trim('"')
    if ([System.IO.Path]::IsPathRooted($value)) {
        $absoluteValue = [System.IO.Path]::GetFullPath($value)
        if (Test-PathWithinDirectory -Path $absoluteValue -Directory $script:UpdaterRepositoryRoot) {
            $repositoryPrefix = $script:UpdaterRepositoryRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
            $relative = if ($absoluteValue.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                $absoluteValue.Substring($repositoryPrefix.Length)
            } else { '' }
            return '%REPOSITORY%' + $(if ([string]::IsNullOrWhiteSpace($relative)) { '' } else { '\' + $relative })
        }
    }
    $locations = @(
        @{ Value=$env:USERPROFILE; Token='%USERPROFILE%' },
        @{ Value=$env:LOCALAPPDATA; Token='%LOCALAPPDATA%' },
        @{ Value=$env:APPDATA; Token='%APPDATA%' }
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Value) } |
        Sort-Object { ([string]$_.Value).Length } -Descending
    foreach ($location in $locations) {
        $prefix = ([string]$location.Value).TrimEnd('\', '/')
        if ($value.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return [string]$location.Token + $value.Substring($prefix.Length)
        }
    }
    if ($value -match '^[A-Za-z]:\\Users\\[^\\]+(?<rest>\\.*)?$') {
        return '%USERPROFILE%' + [string]$Matches['rest']
    }
    if ([System.IO.Path]::IsPathRooted($value)) {
        return '<external>\' + [System.IO.Path]::GetFileName($value.TrimEnd('\', '/'))
    }
    return $value
}

function Get-DefaultUpdaterPrivateKeyPath {
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        throw 'USERPROFILE is unavailable; provide an explicit external KeyPath.'
    }
    return [System.IO.Path]::Combine($env:USERPROFILE, '.tauri', 'qijiang-desktop-pet.key')
}

function Assert-UpdaterPrivateKeyPath {
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [string]$RepositoryRoot = $script:UpdaterRepositoryRoot
    )

    $absolute = Resolve-UpdaterPath -Path $KeyPath -BaseDirectory ((Get-Location).ProviderPath)
    if (Test-PathWithinDirectory -Path $absolute -Directory $RepositoryRoot) {
        throw 'The updater private key must be stored outside the repository.'
    }
    Assert-NoUpdaterReparsePoint -Path $absolute -Purpose 'Updater private key'
    $extension = [System.IO.Path]::GetExtension($absolute)
    if (-not [string]::Equals($extension, '.key', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The updater private key path must use the .key extension.'
    }
    return $absolute
}

function Get-SemVerParts {
    param([Parameter(Mandatory)][string]$Version)

    $pattern = '^(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)(?:-(?<pre>(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+(?<build>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$'
    if ($Version -notmatch $pattern) { throw "Invalid semantic version: $Version" }
    return [pscustomobject]@{
        Original = $Version
        Major = [string]$Matches['major']
        Minor = [string]$Matches['minor']
        Patch = [string]$Matches['patch']
        PreRelease = [string]$Matches['pre']
        Build = [string]$Matches['build']
    }
}

function Compare-NumericIdentifier {
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)
    $leftTrimmed = $Left.TrimStart('0'); if ($leftTrimmed.Length -eq 0) { $leftTrimmed = '0' }
    $rightTrimmed = $Right.TrimStart('0'); if ($rightTrimmed.Length -eq 0) { $rightTrimmed = '0' }
    if ($leftTrimmed.Length -lt $rightTrimmed.Length) { return -1 }
    if ($leftTrimmed.Length -gt $rightTrimmed.Length) { return 1 }
    return [string]::CompareOrdinal($leftTrimmed, $rightTrimmed)
}

function Compare-SemVer {
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)

    $leftParts = Get-SemVerParts -Version $Left
    $rightParts = Get-SemVerParts -Version $Right
    foreach ($name in @('Major', 'Minor', 'Patch')) {
        $comparison = Compare-NumericIdentifier -Left ([string]$leftParts.$name) -Right ([string]$rightParts.$name)
        if ($comparison -ne 0) { return $(if ($comparison -lt 0) { -1 } else { 1 }) }
    }
    $leftPre = [string]$leftParts.PreRelease
    $rightPre = [string]$rightParts.PreRelease
    if ([string]::IsNullOrWhiteSpace($leftPre) -and [string]::IsNullOrWhiteSpace($rightPre)) { return 0 }
    if ([string]::IsNullOrWhiteSpace($leftPre)) { return 1 }
    if ([string]::IsNullOrWhiteSpace($rightPre)) { return -1 }

    $leftIdentifiers = @($leftPre.Split('.'))
    $rightIdentifiers = @($rightPre.Split('.'))
    $count = [Math]::Min($leftIdentifiers.Count, $rightIdentifiers.Count)
    for ($index = 0; $index -lt $count; $index++) {
        $leftIdentifier = [string]$leftIdentifiers[$index]
        $rightIdentifier = [string]$rightIdentifiers[$index]
        $leftNumeric = $leftIdentifier -match '^\d+$'
        $rightNumeric = $rightIdentifier -match '^\d+$'
        if ($leftNumeric -and $rightNumeric) {
            $comparison = Compare-NumericIdentifier -Left $leftIdentifier -Right $rightIdentifier
        } elseif ($leftNumeric) {
            $comparison = -1
        } elseif ($rightNumeric) {
            $comparison = 1
        } else {
            $comparison = [string]::CompareOrdinal($leftIdentifier, $rightIdentifier)
        }
        if ($comparison -ne 0) { return $(if ($comparison -lt 0) { -1 } else { 1 }) }
    }
    if ($leftIdentifiers.Count -lt $rightIdentifiers.Count) { return -1 }
    if ($leftIdentifiers.Count -gt $rightIdentifiers.Count) { return 1 }
    return 0
}

function Assert-UpdaterVersionIncrease {
    param([Parameter(Mandatory)][string]$CurrentVersion, [Parameter(Mandatory)][string]$Version)
    if ((Compare-SemVer -Left $Version -Right $CurrentVersion) -le 0) {
        throw "Updater version must be higher than the current version: current=$CurrentVersion; candidate=$Version"
    }
}

function Get-FileTextWithoutBom {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if (-not [System.IO.File]::Exists($LiteralPath)) { throw "File not found: $LiteralPath" }
    $bytes = [System.IO.File]::ReadAllBytes($LiteralPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "UTF-8 BOM is not allowed: $([System.IO.Path]::GetFileName($LiteralPath))"
    }
    return $script:Utf8NoBom.GetString($bytes)
}

function Get-UpdaterSignatureText {
    param([Parameter(Mandatory)][string]$SignaturePath)
    $signature = (Get-FileTextWithoutBom -LiteralPath $SignaturePath).Trim()
    return Assert-UpdaterSignatureText -Signature $signature
}

function Assert-UpdaterSignatureText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Signature)
    if ([string]::IsNullOrWhiteSpace($Signature)) { throw 'Updater signature file is empty.' }
    if ($Signature -match '(?i)replace|placeholder|example|todo') { throw 'Updater signature contains placeholder text.' }
    if ($Signature.Length -lt 32 -or $Signature -notmatch '^[A-Za-z0-9+/=]+$') {
        throw 'Updater signature is not valid signature-file text.'
    }
    try { $decoded = [Convert]::FromBase64String($Signature) } catch { throw 'Updater signature is not valid Base64.' }
    if ($decoded.Length -lt 48) { throw 'Updater signature payload is unexpectedly short.' }
    $decodedText = [Text.Encoding]::UTF8.GetString($decoded)
    if ($decodedText -match '(?i)replace|placeholder|example|todo') { throw 'Updater signature payload contains placeholder text.' }
    return $Signature
}

function Assert-UpdaterHttpsUrl {
    param([Parameter(Mandatory)][string]$Url)
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
        throw 'Updater download URL must use HTTPS.'
    }
    if (-not [string]::IsNullOrWhiteSpace($uri.UserInfo) -or -not [string]::IsNullOrWhiteSpace($uri.Query) -or -not [string]::IsNullOrWhiteSpace($uri.Fragment)) {
        throw 'Updater download URL must not contain credentials, query parameters, or fragments.'
    }
    $uriHost = $uri.DnsSafeHost.ToLowerInvariant().TrimEnd('.')
    $reservedHosts = @('example.com', 'example.org', 'example.net', 'localhost')
    $reservedSuffixes = @('.example.com', '.example.org', '.example.net', '.invalid', '.example', '.test', '.localhost', '.local')
    if ($reservedHosts -contains $uriHost -or @($reservedSuffixes | Where-Object { $uriHost.EndsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        throw "Updater URL uses a reserved or local-only host: $uriHost"
    }
    $ipAddress = $null
    if ([Net.IPAddress]::TryParse($uriHost, [ref]$ipAddress)) {
        throw 'Updater URL must use an approved public DNS hostname rather than an IP literal.'
    }
    return $uri.AbsoluteUri
}

function Assert-UpdaterArtifactBinding {
    param(
        [Parameter(Mandatory)][string]$ArtifactPath,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$DownloadUrl
    )
    [void](Get-SemVerParts -Version $Version)
    $artifactName = [System.IO.Path]::GetFileName($ArtifactPath)
    if ([string]::IsNullOrWhiteSpace($artifactName)) { throw 'Updater artifact filename is empty.' }
    $versionPattern = '(?<![0-9A-Za-z])' + [regex]::Escape($Version) + '(?![0-9A-Za-z])'
    if ($artifactName -notmatch $versionPattern) {
        throw "Updater artifact filename must contain the exact version $Version."
    }
    $safeUrl = Assert-UpdaterHttpsUrl -Url $DownloadUrl
    $uri = New-Object Uri($safeUrl)
    $urlFilename = [Uri]::UnescapeDataString([System.IO.Path]::GetFileName($uri.AbsolutePath))
    if (-not [string]::Equals($urlFilename, $artifactName, [StringComparison]::Ordinal)) {
        throw "Updater download URL filename must exactly match the artifact filename: artifact=$artifactName; url=$urlFilename"
    }
    return $safeUrl
}

function Assert-UpdaterSignatureBinding {
    param(
        [Parameter(Mandatory)][string]$ArtifactPath,
        [Parameter(Mandatory)][string]$SignaturePath
    )
    $expectedName = [System.IO.Path]::GetFileName($ArtifactPath) + '.sig'
    $actualName = [System.IO.Path]::GetFileName($SignaturePath)
    if (-not [string]::Equals($actualName, $expectedName, [StringComparison]::Ordinal)) {
        throw "Updater signature filename must exactly equal artifact filename plus .sig: expected=$expectedName; actual=$actualName"
    }
}

function Test-UpdaterSensitiveMetadataKey {
    param([Parameter(Mandatory)][string]$Name)

    $normalized = ($Name -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
    foreach ($fragment in @('password','passwd','secret','token','credential','authorization','privatekey','apikey')) {
        if ($normalized.Contains($fragment)) { return $true }
    }
    return $normalized -eq 'pat' -or $normalized -match '^(?:github|personalaccess)pat$'
}

function Assert-NoUpdaterSensitiveJsonKeys {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [System.ValueType]) { return }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if (Test-UpdaterSensitiveMetadataKey -Name ([string]$key)) {
                throw 'Updater metadata contains a sensitive field name.'
            }
            Assert-NoUpdaterSensitiveJsonKeys -Value $Value[$key]
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) { Assert-NoUpdaterSensitiveJsonKeys -Value $item }
        return
    }
    foreach ($property in @($Value.PSObject.Properties | Where-Object {
        $_.MemberType -in @('NoteProperty','Property','AliasProperty','ScriptProperty','CodeProperty')
    })) {
        if (Test-UpdaterSensitiveMetadataKey -Name ([string]$property.Name)) {
            throw 'Updater metadata contains a sensitive field name.'
        }
        Assert-NoUpdaterSensitiveJsonKeys -Value $property.Value
    }
}

function Assert-NoUpdaterSensitiveMetadata {
    param([Parameter(Mandatory)][string]$Text)

    $parsedJson = $null
    $jsonParsed = $false
    try {
        $parsedJson = $Text | ConvertFrom-Json -ErrorAction Stop
        $jsonParsed = $true
    } catch {
        $jsonParsed = $false
    }
    if ($jsonParsed) { Assert-NoUpdaterSensitiveJsonKeys -Value $parsedJson }

    $patterns = @(
        '(?i)(?<![A-Za-z])[A-Z]:[\\/]',
        '(?i)\\\\[^\\]+\\',
        '(?i)/(?:Users|home)/[^/]+/',
        '(?i)TAURI_SIGNING_PRIVATE_KEY',
        '(?i)BEGIN [A-Z ]*PRIVATE KEY',
        '(?i)\bgh[pousr]_[A-Za-z0-9]{20,}\b',
        '(?i)\bgithub_pat_[A-Za-z0-9_]{20,}\b',
        '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{20,}',
        '(?i)(?<![A-Za-z0-9])(?:["'']\s*)?(?:[A-Za-z0-9_-]*(?:password|passwd|secret|token|credential|authorization|private[_-]*key|api[_-]*key)[A-Za-z0-9_-]*|(?:github|personal[_-]*access)?[_-]*pat)(?:\s*["''])?\s*[:=]'
    )
    foreach ($pattern in $patterns) {
        if ($Text -match $pattern) { throw 'Updater metadata contains a local path or secret-like value.' }
    }
}

function New-UpdaterLatestDocument {
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$CurrentVersion,
        [Parameter(Mandatory)][string]$DownloadUrl,
        [Parameter(Mandatory)][string]$Signature,
        [Parameter(Mandatory)][string]$Platform,
        [Parameter(Mandatory)][string]$PublishedAtUtc,
        [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)][long]$ArtifactSizeBytes,
        [AllowEmptyString()][string]$Notes = ''
    )
    [void](Get-SemVerParts -Version $Version)
    [void](Get-SemVerParts -Version $CurrentVersion)
    Assert-UpdaterVersionIncrease -CurrentVersion $CurrentVersion -Version $Version
    $safeUrl = Assert-UpdaterHttpsUrl -Url $DownloadUrl
    if ([string]::IsNullOrWhiteSpace($Platform) -or $Platform -notmatch '^[a-z0-9_-]+$') { throw "Invalid updater platform: $Platform" }
    $published = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($PublishedAtUtc, [ref]$published)) { throw "Invalid publication time: $PublishedAtUtc" }
    $Signature = Assert-UpdaterSignatureText -Signature $Signature

    $document = [ordered]@{
        version = $Version
        notes = $Notes
        pub_date = $published.ToUniversalTime().ToString('o')
        platforms = [ordered]@{
            $Platform = [ordered]@{ signature=$Signature; url=$safeUrl; size=$ArtifactSizeBytes }
        }
    }
    $json = $document | ConvertTo-Json -Depth 8
    Assert-NoUpdaterSensitiveMetadata -Text $json
    return $document
}

function Write-Utf8NoBomJson {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$LiteralPath
    )
    $json = $InputObject | ConvertTo-Json -Depth 12
    Assert-NoUpdaterSensitiveMetadata -Text $json
    [System.IO.File]::WriteAllText($LiteralPath, $json + [Environment]::NewLine, $script:Utf8NoBom)
}

function Test-UpdaterLatestDocument {
    param(
        [Parameter(Mandatory)][string]$LatestJsonPath,
        [Parameter(Mandatory)][string]$CurrentVersion,
        [AllowNull()][string]$ExpectedVersion,
        [AllowNull()][string]$ExpectedPlatform,
        [Nullable[long]]$ExpectedArtifactSizeBytes = $null
    )
    $json = Get-FileTextWithoutBom -LiteralPath $LatestJsonPath
    Assert-NoUpdaterSensitiveMetadata -Text $json
    try { $document = $json | ConvertFrom-Json } catch { throw 'latest.json is not valid JSON.' }
    $topLevelNames = @($document.PSObject.Properties.Name | Sort-Object)
    $expectedTopLevelNames = @('notes','platforms','pub_date','version')
    if (($topLevelNames -join "`n") -cne (($expectedTopLevelNames | Sort-Object) -join "`n")) {
        throw 'latest.json must contain exactly version, notes, pub_date, and platforms.'
    }
    if ($document.version -isnot [string] -or $document.notes -isnot [string] -or $document.pub_date -isnot [string]) {
        throw 'latest.json version, notes, and pub_date must be JSON strings.'
    }
    if ($null -eq $document.platforms -or $document.platforms -is [string] -or $document.platforms -is [System.Collections.IEnumerable]) {
        throw 'latest.json platforms must be a JSON object.'
    }
    $publicationTime = [DateTimeOffset]::MinValue
    if ([string]$document.pub_date -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$' -or
        -not [DateTimeOffset]::TryParse([string]$document.pub_date, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$publicationTime)) {
        throw 'latest.json pub_date must be an RFC3339 timestamp.'
    }
    $version = [string]$document.version
    [void](Get-SemVerParts -Version $version)
    Assert-UpdaterVersionIncrease -CurrentVersion $CurrentVersion -Version $version
    if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion) -and $version -ne $ExpectedVersion) {
        throw "latest.json version mismatch: expected=$ExpectedVersion; actual=$version"
    }
    $platformProperties = @($document.platforms.PSObject.Properties)
    if ($platformProperties.Count -eq 0) { throw 'latest.json contains no platform artifacts.' }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPlatform)) {
        $platformProperties = @($platformProperties | Where-Object { $_.Name -eq $ExpectedPlatform })
        if ($platformProperties.Count -ne 1) { throw "latest.json does not contain platform: $ExpectedPlatform" }
    }
    foreach ($property in $platformProperties) {
        if ([string]$property.Name -notmatch '^[a-z0-9_-]+$') { throw "latest.json contains an invalid platform name: $($property.Name)" }
        $entry = $property.Value
        if ($null -eq $entry -or $entry -is [string] -or $entry -is [System.Collections.IEnumerable]) {
            throw "latest.json platform entry must be a JSON object: $($property.Name)"
        }
        $entryNames = @($entry.PSObject.Properties.Name | Sort-Object)
        if (($entryNames -join "`n") -cne ((@('signature','size','url') | Sort-Object) -join "`n")) {
            throw "latest.json platform entry must contain exactly signature, size, and url: $($property.Name)"
        }
        if ($entry.url -isnot [string] -or $entry.signature -isnot [string]) {
            throw "latest.json platform URL and signature must be JSON strings: $($property.Name)"
        }
        [void](Assert-UpdaterHttpsUrl -Url ([string]$entry.url))
        $sizeProperty = $entry.PSObject.Properties['size']
        if ($null -eq $sizeProperty) { throw "latest.json contains no artifact size for platform: $($property.Name)" }
        $artifactSize = 0L
        if ($sizeProperty.Value -is [string] -or $sizeProperty.Value -is [bool] -or
            -not [long]::TryParse([string]$sizeProperty.Value, [ref]$artifactSize) -or $artifactSize -le 0) {
            throw "latest.json contains an invalid artifact size for platform: $($property.Name)"
        }
        if ($null -ne $ExpectedArtifactSizeBytes -and $artifactSize -ne [long]$ExpectedArtifactSizeBytes) {
            throw "latest.json artifact size mismatch for platform $($property.Name): expected=$ExpectedArtifactSizeBytes; actual=$artifactSize"
        }
        $signature = [string]$entry.signature
        try { [void](Assert-UpdaterSignatureText -Signature $signature) } catch {
            throw "latest.json contains an invalid signature for platform $($property.Name): $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{ Valid=$true; Version=$version; Platforms=@($platformProperties.Name); Path=[System.IO.Path]::GetFileName($LatestJsonPath) }
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][string]$LiteralPath)
    return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-ExactUpdaterInstallerArtifact {
    param(
        [Parameter(Mandatory)][string]$BundleDirectory,
        [Parameter(Mandatory)][string]$ProductName,
        [Parameter(Mandatory)][string]$Version,
        [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Architecture = 'x64'
    )
    [void](Get-SemVerParts -Version $Version)
    if (-not [System.IO.Directory]::Exists($BundleDirectory)) { throw 'The isolated NSIS bundle directory does not exist.' }
    $expectedName = $ProductName + '_' + $Version + '_' + $Architecture + '-setup.exe'
    $installers = @(Get-ChildItem -LiteralPath $BundleDirectory -Filter '*-setup.exe' -File -ErrorAction Stop)
    if ($installers.Count -ne 1 -or $installers[0].Name -cne $expectedName) {
        throw "The isolated signed build did not produce exactly the expected NSIS updater artifact: $expectedName"
    }
    return $installers[0]
}

function Get-UpdaterPublicKeyText {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $publicKeyText = (Get-FileTextWithoutBom -LiteralPath $LiteralPath).Trim()
    if ([string]::IsNullOrWhiteSpace($publicKeyText) -or $publicKeyText.Length -lt 32) {
        throw 'Updater public key file is empty or malformed.'
    }
    if ($publicKeyText -match '(?i)secret key|private key') {
        throw 'The public key file appears to contain private key material.'
    }
    return $publicKeyText
}

function Get-UpdaterPublicKeyFingerprint {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $publicKeyText = Get-UpdaterPublicKeyText -LiteralPath $LiteralPath
    return Get-UpdaterPublicKeyTextFingerprint -PublicKeyText $publicKeyText
}

function Get-UpdaterPublicKeyTextFingerprint {
    param([Parameter(Mandatory)][string]$PublicKeyText)
    $canonicalText = $PublicKeyText.Trim()
    if ([string]::IsNullOrWhiteSpace($canonicalText) -or $canonicalText.Length -lt 32 -or
        $canonicalText -match '(?i)secret key|private key') {
        throw 'Updater public key text is empty or malformed.'
    }
    $bytes = $script:Utf8NoBom.GetBytes($canonicalText)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToUpperInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Write-UpdaterPublicKeySnapshot {
    param(
        [Parameter(Mandatory)][string]$PublicKeyText,
        [Parameter(Mandatory)][string]$LiteralPath
    )
    if ([System.IO.File]::Exists($LiteralPath) -or [System.IO.Directory]::Exists($LiteralPath)) {
        throw 'Refusing to overwrite an updater public-key snapshot path.'
    }
    $canonicalText = $PublicKeyText.Trim()
    [void](Get-UpdaterPublicKeyTextFingerprint -PublicKeyText $canonicalText)
    [System.IO.File]::WriteAllText($LiteralPath, $canonicalText + "`n", $script:Utf8NoBom)
    return $LiteralPath
}

function Invoke-UpdaterToolProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 120
    )
    $process = $null
    try {
        $escapedArguments = @($ArgumentList | ForEach-Object {
            $argument = [string]$_
            if ($argument -match '["\r\n]') { throw 'Native tooling arguments must not contain quotes or line breaks.' }
            if ($argument.Length -eq 0 -or $argument -match '\s') { '"' + $argument + '"' } else { $argument }
        })
        $effectiveFilePath = $FilePath
        $effectiveArguments = $escapedArguments -join ' '
        if ([System.IO.Path]::GetExtension($FilePath) -in @('.cmd', '.bat')) {
            if ($FilePath -match '["\r\n%!]' -or @($ArgumentList | Where-Object { [string]$_ -match '["\r\n&|<>^()%!]' }).Count -gt 0) {
                throw 'Batch tooling paths and arguments must not contain cmd.exe metacharacters.'
            }
            $commandInterpreter = if (-not [string]::IsNullOrWhiteSpace($env:ComSpec)) { $env:ComSpec } else { [System.IO.Path]::Combine($env:SystemRoot, 'System32', 'cmd.exe') }
            $commandLine = '"' + $FilePath + '"' + $(if ($effectiveArguments.Length) { ' ' + $effectiveArguments } else { '' })
            $effectiveFilePath = $commandInterpreter
            $effectiveArguments = '/d /s /c "' + $commandLine + '"'
        }
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $effectiveFilePath
        $startInfo.Arguments = $effectiveArguments
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        # ProcessStartInfo starts directly from the native environment block and avoids the
        # Windows PowerShell Start-Process Path/PATH duplicate-key bug.
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            return 124
        }
        [void]$standardOutput.Result
        [void]$standardError.Result
        return $process.ExitCode
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Test-UpdaterArtifactSignature {
    param(
        [Parameter(Mandatory)][string]$ArtifactPath,
        [Parameter(Mandatory)][string]$SignaturePath,
        [Parameter(Mandatory)][string]$PublicKeyPath,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 120
    )
    if (-not [System.IO.File]::Exists($ArtifactPath)) { throw 'Updater artifact does not exist.' }
    if (-not [System.IO.File]::Exists($PublicKeyPath)) { throw 'Updater public key does not exist.' }
    Assert-UpdaterSignatureBinding -ArtifactPath $ArtifactPath -SignaturePath $SignaturePath
    $signatureText = Get-UpdaterSignatureText -SignaturePath $SignaturePath
    $publicKeyText = Get-UpdaterPublicKeyText -LiteralPath $PublicKeyPath
    $cargo = Get-Command cargo.exe -ErrorAction SilentlyContinue
    if (-not $cargo) { throw 'Cargo is required for offline updater signature verification.' }
    $verifierManifest = [System.IO.Path]::Combine($script:UpdaterToolsDirectory, 'signature-verifier', 'Cargo.toml')
    if (-not [System.IO.File]::Exists($verifierManifest)) { throw 'Updater signature verifier source is missing.' }
    $verifierLock = [System.IO.Path]::Combine($script:UpdaterToolsDirectory, 'signature-verifier', 'Cargo.lock')
    if (-not [System.IO.File]::Exists($verifierLock)) { throw 'Updater signature verifier lock file is missing.' }

    $temporaryDirectory = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'qijiang-updater-verify-' + [Guid]::NewGuid().ToString('N'))
    try {
        [void][System.IO.Directory]::CreateDirectory($temporaryDirectory)
        $verifierTarget = [System.IO.Path]::Combine($temporaryDirectory, 'cargo-target')
        $verifierExecutable = [System.IO.Path]::Combine($verifierTarget, 'release', 'qijiang-updater-signature-verifier.exe')
        $buildExit = Invoke-UpdaterToolProcess -FilePath $cargo.Source -ArgumentList @(
            'build','--release','--offline','--locked','--quiet','--manifest-path',$verifierManifest,'--target-dir',$verifierTarget
        ) -TimeoutSeconds $TimeoutSeconds
        if ($buildExit -eq 124) { throw 'Updater signature verifier compilation timed out.' }
        if ($buildExit -ne 0 -or -not [System.IO.File]::Exists($verifierExecutable)) {
            throw 'Updater signature verifier could not be compiled offline.'
        }
        $decodedSignature = [System.IO.Path]::Combine($temporaryDirectory, 'artifact.sig')
        [System.IO.File]::WriteAllBytes($decodedSignature, [Convert]::FromBase64String($signatureText))
        $normalizedPublicKey = [System.IO.Path]::Combine($temporaryDirectory, 'updater.pub')
        $publicLines = @($publicKeyText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $decodedPublicText = $null
        if ($publicLines.Count -eq 1) {
            try {
                $decodedCandidate = $script:Utf8NoBom.GetString([Convert]::FromBase64String($publicLines[0])).Trim()
                if ($decodedCandidate -match '(?i)^untrusted comment:.*public key') { $decodedPublicText = $decodedCandidate }
            } catch { $decodedPublicText = $null }
        }
        $publicFileText = if (-not [string]::IsNullOrWhiteSpace($decodedPublicText)) {
            $decodedPublicText + "`n"
        } elseif ($publicLines.Count -eq 1) {
            "untrusted comment: qijiang updater public key`n$($publicLines[0])`n"
        } else {
            $publicKeyText + "`n"
        }
        [System.IO.File]::WriteAllText($normalizedPublicKey, $publicFileText, $script:Utf8NoBom)
        $verifyExit = Invoke-UpdaterToolProcess -FilePath $verifierExecutable -ArgumentList @(
            $normalizedPublicKey, $decodedSignature, $ArtifactPath
        ) -TimeoutSeconds $TimeoutSeconds
        if ($verifyExit -eq 124) { throw 'Updater signature verification timed out.' }
        return ($verifyExit -eq 0)
    } finally {
        if ([System.IO.Directory]::Exists($temporaryDirectory)) { [System.IO.Directory]::Delete($temporaryDirectory, $true) }
    }
}

function Get-UpdaterGitState {
    param([string]$RepositoryRoot = $script:UpdaterRepositoryRoot)
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        # Some locked-down Windows profiles expose an unreadable global excludes file.
        # Native Git warnings must not hide the actual exit code or leak profile paths.
        $ErrorActionPreference = 'Continue'
        $commitOutput = @(& git -C $RepositoryRoot -c core.excludesfile= rev-parse HEAD 2>$null)
        $commitExitCode = $LASTEXITCODE
        $statusOutput = @(& git -C $RepositoryRoot -c core.excludesfile= status --porcelain --untracked-files=normal 2>$null)
        $statusExitCode = $LASTEXITCODE
        $diffOutput = @(& git -C $RepositoryRoot -c core.excludesfile= diff --no-ext-diff --binary HEAD -- 2>$null)
        $diffExitCode = $LASTEXITCODE
        $untrackedOutput = @(& git -C $RepositoryRoot -c core.excludesfile= -c core.quotepath=false ls-files --others --exclude-standard 2>$null)
        $untrackedExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($commitExitCode -ne 0 -or $commitOutput.Count -eq 0 -or $statusExitCode -ne 0 -or $diffExitCode -ne 0 -or $untrackedExitCode -ne 0) {
        throw 'Unable to determine the Git commit and worktree state.'
    }
    $commit = ([string]$commitOutput[0]).Trim()
    $untrackedFingerprints = @()
    foreach ($relativePathValue in @($untrackedOutput | Sort-Object)) {
        $relativePath = [string]$relativePathValue
        if ([string]::IsNullOrWhiteSpace($relativePath)) { continue }
        $absolutePath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($RepositoryRoot, $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)))
        if (-not (Test-PathWithinDirectory -Path $absolutePath -Directory $RepositoryRoot) -or -not [System.IO.File]::Exists($absolutePath)) {
            throw 'Unable to fingerprint an untracked Git worktree file.'
        }
        $untrackedFingerprints += $relativePath + ':' + (Get-Sha256Hex -LiteralPath $absolutePath)
    }
    $snapshotText = $commit + "`n" + (($statusOutput | ForEach-Object { [string]$_ }) -join "`n") + `
        "`n--tracked-diff--`n" + (($diffOutput | ForEach-Object { [string]$_ }) -join "`n") + `
        "`n--untracked-files--`n" + ($untrackedFingerprints -join "`n")
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $stateFingerprint = ([BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($snapshotText)))).Replace('-', '')
    } finally {
        $sha256.Dispose()
    }
    return [pscustomobject]@{
        Commit = $commit
        DirtyWorktree = ($statusOutput.Count -gt 0)
        StateFingerprint = $stateFingerprint
    }
}

function Assert-UpdaterGitStateUnchanged {
    param(
        [Parameter(Mandatory)]$InitialState,
        [string]$RepositoryRoot = $script:UpdaterRepositoryRoot,
        [switch]$RequireClean
    )
    $currentState = Get-UpdaterGitState -RepositoryRoot $RepositoryRoot
    if ([string]$currentState.Commit -ne [string]$InitialState.Commit -or
        [string]$currentState.StateFingerprint -ne [string]$InitialState.StateFingerprint) {
        throw 'Git HEAD or worktree changed while updater artifacts were being prepared.'
    }
    if ($RequireClean -and [bool]$currentState.DirtyWorktree) {
        throw 'Refusing to publish updater artifacts from a dirty Git worktree.'
    }
    return $currentState
}

function Convert-SecureStringToUpdaterPlainText {
    param([Parameter(Mandatory)][Security.SecureString]$SecureString)
    $pointer = [IntPtr]::Zero
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
}

function Find-UpdaterSecretIndicators {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if (-not [System.IO.File]::Exists($LiteralPath)) { return @() }
    $item = Get-Item -LiteralPath $LiteralPath
    $extension = $item.Extension.ToLowerInvariant()
    if ($extension -in @('.exe', '.dll', '.ico', '.png', '.jpg', '.jpeg', '.zip', '.msi', '.7z', '.p12', '.pfx')) { return @() }
    if ($item.Length -gt 10MB) {
        return @([pscustomobject]@{ File=$item.Name; Line=0; Category='unscanned-large-file' })
    }
    return @(Find-UpdaterSecretIndicatorsInText -Text ([System.IO.File]::ReadAllText($item.FullName)) -FileName $item.Name)
}

function Find-UpdaterSecretIndicatorsInText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$FileName
    )
    $findings = @()
    $lineNumber = 0
    $privateKeyLiteral = $null
    try { $privateKeyLiteral = Get-DefaultUpdaterPrivateKeyPath } catch { $privateKeyLiteral = $null }
    foreach ($line in @($Text -split "`r?`n")) {
        $lineNumber++
        $category = $null
        if ($line -match '(?i)^\s*(?:untrusted comment:.*secret key|-----BEGIN [A-Z ]*PRIVATE KEY-----)') {
            $category = 'private-key-material'
        } elseif ($line -match '(?i)^\s*TAURI_SIGNING_PRIVATE_KEY(?:_PASSWORD)?\s*[:=]\s*[^\s$%<{][^\s]*') {
            $category = 'signing-environment-value'
        } elseif ($line -match '(?i)\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b') {
            $category = 'github-token-value'
        } elseif ($line -match '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{20,}') {
            $category = 'bearer-token-value'
        } elseif (
            $line -match '(?i)["''](?:updater[_-]?)?(?:password|secret|access[_-]?token|api[_-]?key)["'']?\s*[:=]\s*["''][^"''$%<{][^"'']{7,}["'']' -or
            $line -match '(?i)^\s*(?:updater[_-]?)?(?:password|secret|access[_-]?token|api[_-]?key)\s*[:=]\s*[^\s$%<{][^\s]{7,}\s*$'
        ) {
            $category = 'secret-like-assignment'
        } elseif (-not [string]::IsNullOrWhiteSpace($privateKeyLiteral) -and
            ($line.Replace('\\', '\').Replace('/', '\')).IndexOf($privateKeyLiteral, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $category = 'private-key-absolute-path'
        }
        if ($null -ne $category) {
            $findings += [pscustomobject]@{ File=$FileName; Line=$lineNumber; Category=$category }
        }
    }
    return @($findings)
}

function Publish-UpdaterFileAtomically {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )
    if (-not [System.IO.File]::Exists($SourcePath)) { throw 'Atomic updater source file does not exist.' }
    $destinationDirectory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($DestinationPath))
    [void][System.IO.Directory]::CreateDirectory($destinationDirectory)
    $temporaryPath = [System.IO.Path]::Combine($destinationDirectory, '.publish-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $cleanupPending = $false
    try {
        [System.IO.File]::Copy($SourcePath, $temporaryPath, $false)
        if ([System.IO.File]::Exists($DestinationPath)) {
            $backupPath = [System.IO.Path]::Combine($destinationDirectory, '.replace-backup-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            $replacementCommitted = $false
            try {
                [System.IO.File]::Replace($temporaryPath, $DestinationPath, $backupPath, $true)
                $replacementCommitted = $true
            } finally {
                if ([System.IO.File]::Exists($backupPath)) {
                    try { [System.IO.File]::Delete($backupPath) }
                    catch {
                        if (-not $replacementCommitted) { throw }
                        $cleanupPending = $true
                    }
                }
            }
        } else {
            [System.IO.File]::Move($temporaryPath, $DestinationPath)
        }
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }
    }
    return [pscustomobject]@{ Committed=$true; CleanupPending=$cleanupPending }
}

function Assert-NoUpdaterReparsePoint {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Purpose = 'Updater sensitive',
        [scriptblock]$AttributeResolver
    )
    try { $absolutePath = [System.IO.Path]::GetFullPath($Path) } catch { throw "$Purpose path is invalid." }
    $current = $absolutePath
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        try {
            $attributes = if ($null -eq $AttributeResolver) { [System.IO.File]::GetAttributes($current) } else { & $AttributeResolver $current }
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Purpose paths must not traverse symbolic links, junctions, or mounted-folder reparse points."
            }
        } catch [System.IO.FileNotFoundException] {
        } catch [System.IO.DirectoryNotFoundException] {
        } catch {
            if ($_.Exception.Message -match 'must not traverse') { throw }
            throw "Unable to inspect $($Purpose.ToLowerInvariant()) path for reparse points."
        }
        $parent = [System.IO.Path]::GetDirectoryName($current.TrimEnd('\', '/'))
        if ([string]::IsNullOrWhiteSpace($parent) -or [string]::Equals($parent, $current, [StringComparison]::OrdinalIgnoreCase)) { break }
        $current = $parent
    }
}

function Test-UpdaterKeyFiles {
    param(
        [Parameter(Mandatory)][string]$PrivateKeyPath,
        [Parameter(Mandatory)][string]$PublicKeyPath,
        [string]$RepositoryRoot = $script:UpdaterRepositoryRoot
    )
    $privatePath = Assert-UpdaterPrivateKeyPath -KeyPath $PrivateKeyPath -RepositoryRoot $RepositoryRoot
    if (-not [System.IO.File]::Exists($privatePath)) { throw 'Updater private key file does not exist.' }
    if (-not [System.IO.File]::Exists($PublicKeyPath)) { throw 'Updater public key file does not exist.' }
    Assert-NoUpdaterReparsePoint -Path $PublicKeyPath -Purpose 'Updater public key'
    if ((Get-Item -LiteralPath $privatePath).Length -eq 0) { throw 'Updater private key file is empty.' }
    $privateText = (Get-FileTextWithoutBom -LiteralPath $privatePath).Trim()
    $decodedPrivateText = $privateText
    if ($privateText -notmatch '(?i)^untrusted comment:') {
        try { $decodedPrivateText = $script:Utf8NoBom.GetString([Convert]::FromBase64String($privateText)).Trim() } catch { $decodedPrivateText = $privateText }
    }
    $privateHeader = @($decodedPrivateText -split "`r?`n")[0]
    if ([string]::IsNullOrWhiteSpace($privateHeader) -or $privateHeader -notmatch '(?i)^untrusted comment:.*encrypted secret key') {
        throw 'Updater private key does not use the expected encrypted Tauri key container.'
    }
    [void](Get-UpdaterPublicKeyText -LiteralPath $PublicKeyPath)
    return [pscustomobject]@{
        Valid = $true
        PrivateKeyPath = ConvertTo-UpdaterRedactedPath $privatePath
        PublicKeyPath = ConvertTo-UpdaterRedactedPath $PublicKeyPath
        PublicKeySha256 = Get-UpdaterPublicKeyFingerprint -LiteralPath $PublicKeyPath
        PrivateKeyContainerEncrypted = $true
    }
}

function Get-UpdaterObjectPropertyValue {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Normalize-UpdaterDirectoryPath {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $absolutePath = [System.IO.Path]::GetFullPath($Path)
        $root = [System.IO.Path]::GetPathRoot($absolutePath)
    } catch {
        throw 'Updater key backup directory path is invalid.'
    }
    if ([string]::IsNullOrWhiteSpace($root)) { throw 'Updater key backup directory path has no filesystem root.' }
    $trimmedPath = $absolutePath.TrimEnd('\', '/')
    $trimmedRoot = $root.TrimEnd('\', '/')
    if ([string]::Equals($trimmedPath, $trimmedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $root
    }
    return $trimmedPath
}

function Normalize-UpdaterFilePath {
    param([Parameter(Mandatory)][string]$Path)

    try { return [System.IO.Path]::GetFullPath($Path) } catch { throw 'Updater key file path is invalid.' }
}

function Test-UpdaterPhysicalBusType {
    param([AllowNull()][string]$BusType)

    if ([string]::IsNullOrWhiteSpace($BusType)) { return $false }
    return $BusType.Trim() -in @(
        'ATA', 'SAS', 'SATA', 'SD', 'MMC', 'USB', 'NVMe', 'SCM', 'UFS'
    )
}

function Get-UpdaterStableDiskIdentity {
    param([Parameter(Mandatory)][object]$Disk)

    $uniqueId = [string](Get-UpdaterObjectPropertyValue -InputObject $Disk -Name 'UniqueId')
    if (-not [string]::IsNullOrWhiteSpace($uniqueId)) {
        return 'unique:' + $uniqueId.Trim()
    }
    $serialNumber = [string](Get-UpdaterObjectPropertyValue -InputObject $Disk -Name 'SerialNumber')
    if (-not [string]::IsNullOrWhiteSpace($serialNumber)) {
        return 'serial:' + $serialNumber.Trim()
    }
    return $null
}

function Get-UpdaterBackupVolumeIdentity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$VolumeResolver
    )

    $absolutePath = [System.IO.Path]::GetFullPath($Path)
    if ($null -ne $VolumeResolver) {
        if ($env:DESK_PET_UPDATER_TEST_MODE -ne '1') {
            throw 'The custom backup volume resolver is available only to the isolated updater regression test.'
        }
        $resolved = & $VolumeResolver $absolutePath
        if ($null -eq $resolved) { throw 'The injected backup volume resolver returned no result.' }
        $identity = [string](Get-UpdaterObjectPropertyValue -InputObject $resolved -Name 'Identity')
        $verifiedValue = Get-UpdaterObjectPropertyValue -InputObject $resolved -Name 'Verified'
        $removableValue = Get-UpdaterObjectPropertyValue -InputObject $resolved -Name 'Removable'
        if ([string]::IsNullOrWhiteSpace($identity) -or
            $verifiedValue -isnot [System.Boolean] -or
            $removableValue -isnot [System.Boolean]) {
            throw 'The injected backup volume resolver must return Identity plus strict Boolean Verified and Removable values.'
        }
        $description = [string](Get-UpdaterObjectPropertyValue -InputObject $resolved -Name 'Description')
        return [pscustomobject]@{
            Identity = $identity
            Verified = $verifiedValue
            Description = $(if ([string]::IsNullOrWhiteSpace($description)) { 'injected test volume' } else { $description })
            Removable = $removableValue
        }
    }

    $root = [System.IO.Path]::GetPathRoot($absolutePath)
    if ([string]::IsNullOrWhiteSpace($root)) { throw 'Backup path has no filesystem root.' }
    if ($root.StartsWith('\\')) {
        return [pscustomobject]@{
            Identity = 'network:' + $root.TrimEnd('\').ToLowerInvariant()
            Verified = $false
            Description = 'network share (physical disk cannot be verified)'
            Removable = $false
        }
    }
    if (-not [System.IO.Directory]::Exists($root)) {
        throw 'Backup path is on an unavailable drive.'
    }

    $driveLetter = $root.Substring(0, 1)
    try {
        $partitionCommand = Get-Command Get-Partition -ErrorAction Stop
        $diskCommand = Get-Command Get-Disk -ErrorAction Stop
        if ($null -eq $partitionCommand -or $null -eq $diskCommand) { throw 'Storage cmdlets are unavailable.' }
        $partitions = @(Get-Partition -DriveLetter $driveLetter -ErrorAction Stop)
        if ($partitions.Count -ne 1) { throw 'The drive did not map to exactly one partition.' }
        $diskNumberValue = Get-UpdaterObjectPropertyValue -InputObject $partitions[0] -Name 'DiskNumber'
        if ($null -eq $diskNumberValue) { throw 'The partition has no disk number.' }
        $disks = @(Get-Disk -Number ([uint32]$diskNumberValue) -ErrorAction Stop)
        if ($disks.Count -ne 1) { throw 'The partition did not map to exactly one physical disk.' }
        $disk = $disks[0]
        $identityValue = Get-UpdaterStableDiskIdentity -Disk $disk
        if ([string]::IsNullOrWhiteSpace($identityValue)) {
            throw 'The physical disk has no usable identity.'
        }
        $busType = [string](Get-UpdaterObjectPropertyValue -InputObject $disk -Name 'BusType')
        if (-not (Test-UpdaterPhysicalBusType -BusType $busType)) {
            return [pscustomobject]@{
                Identity = 'unverified-bus:' + $(if ([string]::IsNullOrWhiteSpace($busType)) { 'unknown' } else { $busType.ToLowerInvariant() })
                Verified = $false
                Description = 'virtual, pooled, remote, or unknown storage bus'
                Removable = $false
            }
        }
        $driveInfo = New-Object System.IO.DriveInfo($driveLetter)
        $isRemovable = $driveInfo.DriveType -eq [System.IO.DriveType]::Removable -or $busType -in @('USB', 'SD', 'MMC')
        $description = if ($isRemovable) {
            $(if ([string]::IsNullOrWhiteSpace($busType)) { 'removable physical disk' } else { "$busType removable physical disk" })
        } else {
            $(if ([string]::IsNullOrWhiteSpace($busType)) { 'physical disk' } else { "$busType physical disk" })
        }
        return [pscustomobject]@{
            Identity = 'disk:' + $identityValue.ToLowerInvariant()
            Verified = $true
            Description = $description
            Removable = $isRemovable
        }
    } catch {
        return [pscustomobject]@{
            Identity = 'unverified-volume:' + $root.ToLowerInvariant()
            Verified = $false
            Description = 'filesystem volume (physical disk could not be verified; an elevated PowerShell session may be required)'
            Removable = $false
        }
    }
}

function Assert-NoUpdaterBackupReparsePoint {
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$AttributeResolver
    )

    try { $absolutePath = [System.IO.Path]::GetFullPath($Path) } catch { throw 'Updater key backup path is invalid.' }
    $current = $absolutePath
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $fileExists = [System.IO.File]::Exists($current)
        $attributesAvailable = $false
        try {
            $attributes = if ($null -eq $AttributeResolver) {
                [System.IO.File]::GetAttributes($current)
            } else {
                & $AttributeResolver $current
            }
            $attributesAvailable = $true
        } catch [System.IO.FileNotFoundException] {
            $attributesAvailable = $false
        } catch [System.IO.DirectoryNotFoundException] {
            $attributesAvailable = $false
        } catch {
            throw 'Unable to inspect updater key backup path for reparse points.'
        }
        if ($attributesAvailable) {
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Updater key backup paths must not traverse symbolic links, junctions, or mounted-folder reparse points.'
            }
        }
        $parent = if ($fileExists) {
            [System.IO.Path]::GetDirectoryName($current)
        } else {
            [System.IO.Path]::GetDirectoryName($current.TrimEnd('\', '/'))
        }
        if ([string]::IsNullOrWhiteSpace($parent) -or [string]::Equals($parent, $current, [StringComparison]::OrdinalIgnoreCase)) { break }
        $current = $parent
    }
}

function Assert-UpdaterBackupStorageSafety {
    param(
        [Parameter(Mandatory)][string]$PrivateKeyPath,
        [Parameter(Mandatory)][string]$PublicKeyPath,
        [Parameter(Mandatory)][string]$BackupDirectoryOne,
        [Parameter(Mandatory)][string]$BackupDirectoryTwo,
        [AllowNull()][string]$PendingDestinationPath,
        [scriptblock]$VolumeResolver,
        [AllowNull()][object]$Baseline
    )

    foreach ($path in @($PrivateKeyPath, $PublicKeyPath, $BackupDirectoryOne, $BackupDirectoryTwo)) {
        Assert-NoUpdaterBackupReparsePoint -Path $path
    }
    if (-not [string]::IsNullOrWhiteSpace($PendingDestinationPath)) {
        Assert-NoUpdaterBackupReparsePoint -Path $PendingDestinationPath
    }

    $privatePath = [System.IO.Path]::GetFullPath($PrivateKeyPath)
    $publicPath = [System.IO.Path]::GetFullPath($PublicKeyPath)
    $directoryOne = Normalize-UpdaterDirectoryPath -Path $BackupDirectoryOne
    $directoryTwo = Normalize-UpdaterDirectoryPath -Path $BackupDirectoryTwo
    $sourceVolume = Get-UpdaterBackupVolumeIdentity -Path $privatePath -VolumeResolver $VolumeResolver
    $publicSourceVolume = Get-UpdaterBackupVolumeIdentity -Path $publicPath -VolumeResolver $VolumeResolver
    $volumeOne = Get-UpdaterBackupVolumeIdentity -Path $BackupDirectoryOne -VolumeResolver $VolumeResolver
    $volumeTwo = Get-UpdaterBackupVolumeIdentity -Path $BackupDirectoryTwo -VolumeResolver $VolumeResolver
    if (-not $sourceVolume.Verified -or -not $publicSourceVolume.Verified -or
        -not $volumeOne.Verified -or -not $volumeTwo.Verified) {
        throw 'Unable to prove that the source and both backup locations are on separate physical disks. Re-run from an elevated PowerShell session after connecting both backup media.'
    }
    if (-not [string]::Equals([string]$sourceVolume.Identity, [string]$publicSourceVolume.Identity, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The updater private and public key sources must remain on the same verified physical disk.'
    }
    if (-not $volumeOne.Removable -or -not $volumeTwo.Removable) {
        throw 'Both updater key backup targets must be USB, SD, MMC, or Windows removable-drive media.'
    }
    $identities = @([string]$sourceVolume.Identity, [string]$volumeOne.Identity, [string]$volumeTwo.Identity)
    if (@($identities | Sort-Object -Unique).Count -ne 3) {
        throw 'The source and both updater key backups must be on three separate physical disks.'
    }

    $snapshot = [pscustomobject]@{
        Source = $sourceVolume
        PublicSource = $publicSourceVolume
        BackupOne = $volumeOne
        BackupTwo = $volumeTwo
        PrivateKeyPath = $privatePath
        PublicKeyPath = $publicPath
        BackupDirectoryOne = $directoryOne
        BackupDirectoryTwo = $directoryTwo
        PrivateKeyRoot = [System.IO.Path]::GetPathRoot($privatePath)
        PublicKeyRoot = [System.IO.Path]::GetPathRoot($publicPath)
        BackupOneRoot = [System.IO.Path]::GetPathRoot($directoryOne)
        BackupTwoRoot = [System.IO.Path]::GetPathRoot($directoryTwo)
    }

    if ($null -ne $Baseline) {
        $comparisons = @(
            [pscustomobject]@{ Name='PrivateKeyPath'; Actual=[string]$snapshot.PrivateKeyPath },
            [pscustomobject]@{ Name='PublicKeyPath'; Actual=[string]$snapshot.PublicKeyPath },
            [pscustomobject]@{ Name='BackupDirectoryOne'; Actual=[string]$snapshot.BackupDirectoryOne },
            [pscustomobject]@{ Name='BackupDirectoryTwo'; Actual=[string]$snapshot.BackupDirectoryTwo },
            [pscustomobject]@{ Name='PrivateKeyRoot'; Actual=[string]$snapshot.PrivateKeyRoot },
            [pscustomobject]@{ Name='PublicKeyRoot'; Actual=[string]$snapshot.PublicKeyRoot },
            [pscustomobject]@{ Name='BackupOneRoot'; Actual=[string]$snapshot.BackupOneRoot },
            [pscustomobject]@{ Name='BackupTwoRoot'; Actual=[string]$snapshot.BackupTwoRoot },
            [pscustomobject]@{ Name='SourceIdentity'; Actual=[string]$snapshot.Source.Identity },
            [pscustomobject]@{ Name='PublicSourceIdentity'; Actual=[string]$snapshot.PublicSource.Identity },
            [pscustomobject]@{ Name='BackupOneIdentity'; Actual=[string]$snapshot.BackupOne.Identity },
            [pscustomobject]@{ Name='BackupTwoIdentity'; Actual=[string]$snapshot.BackupTwo.Identity }
        )
        foreach ($comparison in $comparisons) {
            $name = [string]$comparison.Name
            $actual = [string]$comparison.Actual
            $expected = if ($name -eq 'SourceIdentity') {
                [string]$Baseline.Source.Identity
            } elseif ($name -eq 'PublicSourceIdentity') {
                [string]$Baseline.PublicSource.Identity
            } elseif ($name -eq 'BackupOneIdentity') {
                [string]$Baseline.BackupOne.Identity
            } elseif ($name -eq 'BackupTwoIdentity') {
                [string]$Baseline.BackupTwo.Identity
            } else {
                [string](Get-UpdaterObjectPropertyValue -InputObject $Baseline -Name $name)
            }
            if ([string]::IsNullOrWhiteSpace($expected) -or
                -not [string]::Equals($expected, $actual, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Updater key backup storage identity or path role changed after confirmation.'
            }
        }
    }

    return $snapshot
}

function Get-UpdaterBackupFileHash {
    param([Parameter(Mandatory)][string]$LiteralPath)

    if (-not [System.IO.File]::Exists($LiteralPath)) { throw 'Backup hash source file does not exist.' }
    $stream = $null
    $sha256 = $null
    try {
        $stream = [System.IO.File]::OpenRead($LiteralPath)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToUpperInvariant()
    } catch {
        throw 'Unable to read an updater key backup file for SHA-256 verification.'
    } finally {
        if ($null -ne $sha256) { $sha256.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Copy-UpdaterBackupFileVerified {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [scriptblock]$CopyAction,
        [scriptblock]$AuthorizedCleanupAction
    )

    if ($null -ne $CopyAction -and $env:DESK_PET_UPDATER_TEST_MODE -ne '1') {
        throw 'The custom updater backup copy action is available only to the isolated updater regression test.'
    }
    if (-not [System.IO.File]::Exists($SourcePath)) { throw 'Updater backup source file does not exist.' }
    if ([System.IO.File]::Exists($DestinationPath)) { throw 'Refusing to overwrite an existing updater key backup.' }
    $sourceHash = Get-UpdaterBackupFileHash -LiteralPath $SourcePath
    $safeFailure = $null
    try {
        if ($null -eq $CopyAction) {
            [System.IO.File]::Copy($SourcePath, $DestinationPath, $false)
        } else {
            & $CopyAction $SourcePath $DestinationPath
        }
        if (-not [System.IO.File]::Exists($DestinationPath)) { throw 'Updater backup copy did not create the expected file.' }
        $destinationHash = Get-UpdaterBackupFileHash -LiteralPath $DestinationPath
        if (-not [string]::Equals($sourceHash, $destinationHash, [StringComparison]::Ordinal)) {
            throw 'Updater key backup SHA-256 verification failed.'
        }
        return $destinationHash
    } catch {
        $message = [string]$_.Exception.Message
        $safeFailure = if ($message -in @(
            'Updater backup copy did not create the expected file.',
            'Updater key backup SHA-256 verification failed.',
            'Unable to read an updater key backup file for SHA-256 verification.'
        )) { $message } else { 'Updater key backup copy or verification failed.' }
        if ([System.IO.File]::Exists($DestinationPath)) {
            if ($null -eq $AuthorizedCleanupAction) {
                throw 'Updater key backup verification failed and the unverified destination was left for manual inspection.'
            }
            try {
                & $AuthorizedCleanupAction $DestinationPath
            } catch {
                throw 'Updater key backup verification failed and automatic cleanup was stopped because storage identity or path safety could not be revalidated. Stop and inspect the destination media manually.'
            }
            if ([System.IO.File]::Exists($DestinationPath)) {
                throw 'Updater key backup verification failed and the unverified destination could not be removed. Stop and inspect the destination media manually.'
            }
        }
        throw $safeFailure
    }
}

function New-UpdaterKeyBackupPlan {
    param(
        [Parameter(Mandatory)][string]$PrivateKeyPath,
        [Parameter(Mandatory)][string]$PublicKeyPath,
        [Parameter(Mandatory)][string]$BackupDirectoryOne,
        [Parameter(Mandatory)][string]$BackupDirectoryTwo,
        [string]$RepositoryRoot = $script:UpdaterRepositoryRoot,
        [scriptblock]$VolumeResolver
    )

    $privatePath = Assert-UpdaterPrivateKeyPath -KeyPath (Normalize-UpdaterFilePath -Path $PrivateKeyPath) -RepositoryRoot $RepositoryRoot
    $publicPath = Normalize-UpdaterFilePath -Path $PublicKeyPath
    if (Test-PathWithinDirectory -Path $publicPath -Directory $RepositoryRoot) {
        throw 'The updater public key source used for backup must be outside the repository.'
    }
    Assert-NoUpdaterBackupReparsePoint -Path $privatePath
    Assert-NoUpdaterBackupReparsePoint -Path $publicPath
    try {
        $keyValidation = Test-UpdaterKeyFiles -PrivateKeyPath $privatePath -PublicKeyPath $publicPath -RepositoryRoot $RepositoryRoot
    } catch {
        $message = [string]$_.Exception.Message
        $safeValidationPatterns = @(
            '^Updater private key file does not exist\.$',
            '^Updater public key file does not exist\.$',
            '^Updater private key file is empty\.$',
            '^Updater private key does not use the expected encrypted Tauri key container\.$',
            '^Updater public key file is empty or malformed\.$',
            '^The public key file appears to contain private key material\.$',
            '^UTF-8 BOM is not allowed: [^\\/:]+$'
        )
        $isSafeValidationError = @($safeValidationPatterns | Where-Object { $message -match $_ }).Count -gt 0
        if ($isSafeValidationError) { throw $message }
        throw 'Unable to validate the updater key pair for backup.'
    }
    $directoryOne = Normalize-UpdaterDirectoryPath -Path $BackupDirectoryOne
    $directoryTwo = Normalize-UpdaterDirectoryPath -Path $BackupDirectoryTwo
    if ([string]::Equals($directoryOne, $directoryTwo, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The two updater key backup directories must be different.'
    }
    foreach ($directory in @($directoryOne, $directoryTwo)) {
        if (Test-PathWithinDirectory -Path $directory -Directory $RepositoryRoot) {
            throw 'Updater key backup directories must be outside the repository.'
        }
        Assert-NoUpdaterBackupReparsePoint -Path $directory
    }

    $privateName = [System.IO.Path]::GetFileName($privatePath)
    $publicName = [System.IO.Path]::GetFileName($publicPath)
    if ([string]::Equals($privateName, $publicName, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The updater private and public key backup filenames must be different.'
    }
    $destinationFiles = @(
        [System.IO.Path]::Combine($directoryOne, $privateName),
        [System.IO.Path]::Combine($directoryOne, $publicName),
        [System.IO.Path]::Combine($directoryTwo, $privateName),
        [System.IO.Path]::Combine($directoryTwo, $publicName)
    )
    foreach ($destinationFile in $destinationFiles) {
        if ([System.IO.File]::Exists($destinationFile)) {
            throw 'Refusing to overwrite an existing updater key backup.'
        }
    }

    $storageSafety = Assert-UpdaterBackupStorageSafety -PrivateKeyPath $privatePath -PublicKeyPath $publicPath `
        -BackupDirectoryOne $directoryOne -BackupDirectoryTwo $directoryTwo -VolumeResolver $VolumeResolver
    $volumeOne = $storageSafety.BackupOne
    $volumeTwo = $storageSafety.BackupTwo

    return [pscustomobject]@{
        Mode = 'ValidatedPlan'
        Source = ConvertTo-UpdaterRedactedPath $privatePath
        PublicKeyFingerprint = [string]$keyValidation.PublicKeySha256
        BackupTargets = @(
            [pscustomobject]@{ Path=ConvertTo-UpdaterRedactedPath $directoryOne; Media=[string]$volumeOne.Description; Removable=[bool]$volumeOne.Removable },
            [pscustomobject]@{ Path=ConvertTo-UpdaterRedactedPath $directoryTwo; Media=[string]$volumeTwo.Description; Removable=[bool]$volumeTwo.Removable }
        )
        FilesToCopy = 4
        OfflineAfterCopy = $false
        RequiredFinalAction = 'Safely eject or physically disconnect both backup media, then store them separately.'
    }
}

function Invoke-UpdaterKeyBackup {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][string]$PrivateKeyPath,
        [Parameter(Mandatory)][string]$PublicKeyPath,
        [Parameter(Mandatory)][string]$BackupDirectoryOne,
        [Parameter(Mandatory)][string]$BackupDirectoryTwo,
        [string]$RepositoryRoot = $script:UpdaterRepositoryRoot,
        [scriptblock]$VolumeResolver,
        [scriptblock]$CopyAction
    )

    if ($null -ne $CopyAction -and $env:DESK_PET_UPDATER_TEST_MODE -ne '1') {
        throw 'The custom updater backup copy action is available only to the isolated updater regression test.'
    }
    $privatePath = Normalize-UpdaterFilePath -Path $PrivateKeyPath
    $publicPath = Normalize-UpdaterFilePath -Path $PublicKeyPath
    $directoryOne = Normalize-UpdaterDirectoryPath -Path $BackupDirectoryOne
    $directoryTwo = Normalize-UpdaterDirectoryPath -Path $BackupDirectoryTwo
    $plan = New-UpdaterKeyBackupPlan -PrivateKeyPath $privatePath -PublicKeyPath $publicPath `
        -BackupDirectoryOne $directoryOne -BackupDirectoryTwo $directoryTwo -RepositoryRoot $RepositoryRoot `
        -VolumeResolver $VolumeResolver
    if (-not $PSCmdlet.ShouldProcess('two verified external backup media', 'Copy and SHA-256 verify the encrypted updater key pair')) {
        $plan.Mode = 'PreviewOnly'
        return $plan
    }

    # Confirmation can leave an arbitrarily long gap after the first validation.
    # Rebuild the complete plan before the first mutation so a swapped drive,
    # newly created file, or newly introduced reparse point fails closed.
    $plan = New-UpdaterKeyBackupPlan -PrivateKeyPath $privatePath -PublicKeyPath $publicPath `
        -BackupDirectoryOne $directoryOne -BackupDirectoryTwo $directoryTwo -RepositoryRoot $RepositoryRoot `
        -VolumeResolver $VolumeResolver
    $storageBaseline = Assert-UpdaterBackupStorageSafety -PrivateKeyPath $privatePath -PublicKeyPath $publicPath `
        -BackupDirectoryOne $directoryOne -BackupDirectoryTwo $directoryTwo -VolumeResolver $VolumeResolver

    $createdDirectories = New-Object System.Collections.Generic.List[string]
    $createdFiles = New-Object System.Collections.Generic.List[string]
    $authorizedDestinationCleanup = {
        param([string]$DestinationPath)
        [void](Assert-UpdaterBackupStorageSafety -PrivateKeyPath $privatePath -PublicKeyPath $publicPath `
            -BackupDirectoryOne $directoryOne -BackupDirectoryTwo $directoryTwo `
            -PendingDestinationPath $DestinationPath -VolumeResolver $VolumeResolver -Baseline $storageBaseline)
        if ([System.IO.File]::Exists($DestinationPath)) {
            [System.IO.File]::Delete($DestinationPath)
        }
    }.GetNewClosure()
    try {
        foreach ($directory in @($directoryOne, $directoryTwo)) {
            [void](Assert-UpdaterBackupStorageSafety -PrivateKeyPath $privatePath -PublicKeyPath $publicPath `
                -BackupDirectoryOne $directoryOne -BackupDirectoryTwo $directoryTwo `
                -VolumeResolver $VolumeResolver -Baseline $storageBaseline)
            if (-not [System.IO.Directory]::Exists($directory)) {
                [void][System.IO.Directory]::CreateDirectory($directory)
                $createdDirectories.Add($directory)
            }
            [void](Assert-UpdaterBackupStorageSafety -PrivateKeyPath $privatePath -PublicKeyPath $publicPath `
                -BackupDirectoryOne $directoryOne -BackupDirectoryTwo $directoryTwo `
                -VolumeResolver $VolumeResolver -Baseline $storageBaseline)
        }
        foreach ($directory in @($directoryOne, $directoryTwo)) {
            foreach ($source in @($privatePath, $publicPath)) {
                $destination = [System.IO.Path]::Combine($directory, [System.IO.Path]::GetFileName($source))
                [void](Assert-UpdaterBackupStorageSafety -PrivateKeyPath $privatePath -PublicKeyPath $publicPath `
                    -BackupDirectoryOne $directoryOne -BackupDirectoryTwo $directoryTwo `
                    -PendingDestinationPath $destination -VolumeResolver $VolumeResolver -Baseline $storageBaseline)
                [void](Copy-UpdaterBackupFileVerified -SourcePath $source -DestinationPath $destination `
                    -CopyAction $CopyAction -AuthorizedCleanupAction $authorizedDestinationCleanup)
                $createdFiles.Add($destination)
            }
        }
        $plan.Mode = 'Completed'
        $plan.OfflineAfterCopy = $false
        return $plan
    } catch {
        $message = [string]$_.Exception.Message
        $safeFailure = if ($message -in @(
            'Updater backup source file does not exist.',
            'Refusing to overwrite an existing updater key backup.',
            'Updater backup copy did not create the expected file.',
            'Updater key backup SHA-256 verification failed.',
            'Unable to read an updater key backup file for SHA-256 verification.',
            'Updater key backup copy or verification failed.',
            'Updater key backup verification failed and the unverified destination was left for manual inspection.',
            'Updater key backup verification failed and automatic cleanup was stopped because storage identity or path safety could not be revalidated. Stop and inspect the destination media manually.',
            'Updater key backup verification failed and the unverified destination could not be removed. Stop and inspect the destination media manually.',
            'Unable to prove that the source and both backup locations are on separate physical disks. Re-run from an elevated PowerShell session after connecting both backup media.',
            'Both updater key backup targets must be USB, SD, MMC, or Windows removable-drive media.',
            'The source and both updater key backups must be on three separate physical disks.',
            'The updater private and public key sources must remain on the same verified physical disk.',
            'Updater key backup storage identity or path role changed after confirmation.',
            'Updater key backup paths must not traverse symbolic links, junctions, or mounted-folder reparse points.',
            'Unable to inspect updater key backup path for reparse points.',
            'Backup path is on an unavailable drive.'
        )) { $message } else { 'Updater key backup failed during directory creation or verified copy.' }
        $cleanupFailed = $false
        $cleanupSafetyChanged = $false
        foreach ($createdFile in $createdFiles) {
            try {
                [void](Assert-UpdaterBackupStorageSafety -PrivateKeyPath $privatePath -PublicKeyPath $publicPath `
                    -BackupDirectoryOne $directoryOne -BackupDirectoryTwo $directoryTwo `
                    -PendingDestinationPath $createdFile -VolumeResolver $VolumeResolver -Baseline $storageBaseline)
            } catch {
                $cleanupSafetyChanged = $true
                break
            }
            try {
                if ([System.IO.File]::Exists($createdFile)) { [System.IO.File]::Delete($createdFile) }
            } catch { $cleanupFailed = $true }
        }
        if (-not $cleanupSafetyChanged) {
            foreach ($createdDirectory in @($createdDirectories | Sort-Object Length -Descending)) {
                try {
                    [void](Assert-UpdaterBackupStorageSafety -PrivateKeyPath $privatePath -PublicKeyPath $publicPath `
                        -BackupDirectoryOne $directoryOne -BackupDirectoryTwo $directoryTwo `
                        -PendingDestinationPath $createdDirectory -VolumeResolver $VolumeResolver -Baseline $storageBaseline)
                } catch {
                    $cleanupSafetyChanged = $true
                    break
                }
                try {
                    if ([System.IO.Directory]::Exists($createdDirectory) -and [System.IO.Directory]::GetFileSystemEntries($createdDirectory).Count -eq 0) {
                        [System.IO.Directory]::Delete($createdDirectory, $false)
                    }
                } catch { $cleanupFailed = $true }
            }
        }
        if ($cleanupSafetyChanged) {
            throw 'Updater key backup failed and automatic cleanup was stopped because storage identity or path safety changed. Stop and inspect both destination media manually.'
        }
        if ($cleanupFailed) {
            throw 'Updater key backup failed and files created by this invocation could not be fully removed. Stop and inspect both destination media manually.'
        }
        throw $safeFailure
    }
}
