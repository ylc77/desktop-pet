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
        throw "Updater download URL must use HTTPS: $Url"
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

function Assert-NoUpdaterSensitiveMetadata {
    param([Parameter(Mandatory)][string]$Text)
    $patterns = @(
        '(?i)(?<![A-Za-z])[A-Z]:[\\/]',
        '(?i)\\\\[^\\]+\\',
        '(?i)/(?:Users|home)/[^/]+/',
        '(?i)TAURI_SIGNING_PRIVATE_KEY',
        '(?i)BEGIN [A-Z ]*PRIVATE KEY',
        '(?i)(?:password|passwd|secret|access[_-]?token|api[_-]?key)\s*[:=]'
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
        $entry = $property.Value
        [void](Assert-UpdaterHttpsUrl -Url ([string]$entry.url))
        $sizeProperty = $entry.PSObject.Properties['size']
        if ($null -eq $sizeProperty) { throw "latest.json contains no artifact size for platform: $($property.Name)" }
        $artifactSize = 0L
        if (-not [long]::TryParse([string]$sizeProperty.Value, [ref]$artifactSize) -or $artifactSize -le 0) {
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
    $bytes = $script:Utf8NoBom.GetBytes($publicKeyText)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToUpperInvariant()
    } finally {
        $sha256.Dispose()
    }
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
    $verifierSource = [System.IO.Path]::Combine($script:UpdaterToolsDirectory, 'signature-verifier', 'src', 'main.rs')
    $verifierTarget = [System.IO.Path]::Combine($script:UpdaterRepositoryRoot, 'src-tauri', 'target', 'updater-signature-verifier')
    $verifierExecutable = [System.IO.Path]::Combine($verifierTarget, 'debug', 'qijiang-updater-signature-verifier.exe')
    $needsBuild = -not [System.IO.File]::Exists($verifierExecutable)
    if (-not $needsBuild) {
        $executableTimestamp = (Get-Item -LiteralPath $verifierExecutable).LastWriteTimeUtc
        $needsBuild = (Get-Item -LiteralPath $verifierManifest).LastWriteTimeUtc -gt $executableTimestamp -or
            (Get-Item -LiteralPath $verifierSource).LastWriteTimeUtc -gt $executableTimestamp
    }
    if ($needsBuild) {
        $buildExit = Invoke-UpdaterToolProcess -FilePath $cargo.Source -ArgumentList @(
            'build','--offline','--locked','--quiet','--manifest-path',$verifierManifest,'--target-dir',$verifierTarget
        ) -TimeoutSeconds $TimeoutSeconds
        if ($buildExit -eq 124) { throw 'Updater signature verifier compilation timed out.' }
        if ($buildExit -ne 0 -or -not [System.IO.File]::Exists($verifierExecutable)) {
            throw 'Updater signature verifier could not be compiled offline.'
        }
    }

    $temporaryDirectory = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'qijiang-updater-verify-' + [Guid]::NewGuid().ToString('N'))
    try {
        [void][System.IO.Directory]::CreateDirectory($temporaryDirectory)
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
        $commitOutput = @(& git -C $RepositoryRoot rev-parse HEAD 2>$null)
        $commitExitCode = $LASTEXITCODE
        $statusOutput = @(& git -C $RepositoryRoot status --porcelain --untracked-files=normal 2>$null)
        $statusExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($commitExitCode -ne 0 -or $commitOutput.Count -eq 0 -or $statusExitCode -ne 0) {
        throw 'Unable to determine the Git commit and worktree state.'
    }
    return [pscustomobject]@{
        Commit = ([string]$commitOutput[0]).Trim()
        DirtyWorktree = ($statusOutput.Count -gt 0)
    }
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
    if ($item.Length -gt 10MB) { return @() }
    $extension = $item.Extension.ToLowerInvariant()
    if ($extension -in @('.exe', '.dll', '.ico', '.png', '.jpg', '.jpeg', '.zip', '.msi', '.7z', '.p12', '.pfx')) { return @() }
    $findings = @()
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadLines($item.FullName)) {
        $lineNumber++
        $category = $null
        if ($line -match '(?i)^\s*(?:untrusted comment:.*secret key|-----BEGIN [A-Z ]*PRIVATE KEY-----)') {
            $category = 'private-key-material'
        } elseif ($line -match '(?i)^\s*TAURI_SIGNING_PRIVATE_KEY(?:_PASSWORD)?\s*[:=]\s*[^\s$%<{][^\s]*') {
            $category = 'signing-environment-value'
        } elseif (
            $line -match '(?i)["''](?:updater[_-]?)?(?:password|secret|access[_-]?token|api[_-]?key)["'']?\s*[:=]\s*["''][^"''$%<{][^"'']{7,}["'']' -or
            $line -match '(?i)^\s*(?:updater[_-]?)?(?:password|secret|access[_-]?token|api[_-]?key)\s*[:=]\s*[^\s$%<{][^\s]{7,}\s*$'
        ) {
            $category = 'secret-like-assignment'
        }
        if ($null -ne $category) {
            $findings += [pscustomobject]@{ File=$item.Name; Line=$lineNumber; Category=$category }
        }
    }
    return @($findings)
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
